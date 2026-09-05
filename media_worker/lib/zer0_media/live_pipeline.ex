defmodule Zer0Media.LivePipeline do
  @moduledoc """
  Per-session Membrane pipeline that ingests RTMP and delivers **both** HLS and
  WebRTC from a single source, using `BroadcastTee` to split each track.

  HLS uses `Membrane.HTTPAdaptiveStream.SinkBin`. WebRTC uses
  `Membrane.WebRTC.ExWebRTCSink` wrapped in `Zer0Media.WebRTCBin`.

  HLS drives the primary pads. Each viewer gets a separate signaling relay,
  sink and temporary crash group. Secondary pads are linked after negotiation
  and connection, and cannot backpressure HLS or other viewers.
  """
  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.{AAC, H264, Opus, RTMP}
  alias Membrane.HTTPAdaptiveStream

  @impl true
  def handle_init(_ctx, opts) do
    client_ref = Keyword.fetch!(opts, :client_ref)
    output_dir = Keyword.fetch!(opts, :output_dir)
    session_id = Keyword.get(opts, :session_id)

    source = Keyword.get(opts, :source, %RTMP.SourceBin{client_ref: client_ref})

    seg_dur = configured_segment_duration()
    video_scale = configured_rate(:video_timestamp_scale, 1.0)
    audio_rate = configured_rate(:aac_timestamp_rate, 1.0)

    structure = [
      # Audio: tee raw AAC → HLS (master) / WebRTC (linked on connect).
      child(:source, source)
      |> via_out(:audio)
      |> child(:audio_tee, Zer0Media.BroadcastTee)
      |> via_out(:primary)
      |> child(:audio_parser_hls, %AAC.Parser{out_encapsulation: :none, output_config: :esds})
      |> child(:audio_normalizer, %Zer0Media.AudioTimestampNormalizer{rate: audio_rate})
      |> via_in(Pad.ref(:input, :audio),
        options: [encoding: :AAC, segment_duration: seg_dur]
      )
      |> get_child(:hls),

      # Video: preserve publisher timing by default, then tee → HLS.
      get_child(:source)
      |> via_out(:video)
      |> child(:video_parser, %H264.Parser{output_stream_structure: :avc1})
      |> child(:video_scaler, %Zer0Media.TimestampScaler{scale: video_scale})
      |> child(:video_tee, Zer0Media.BroadcastTee)
      |> via_out(:primary)
      |> via_in(Pad.ref(:input, :video),
        options: [encoding: :H264, segment_duration: seg_dur]
      )
      |> get_child(:hls),

      # Sinks
      child(:hls, %HTTPAdaptiveStream.SinkBin{
        manifest_name: "master",
        manifest_module: HTTPAdaptiveStream.HLS,
        storage: %HTTPAdaptiveStream.Storages.FileStorage{directory: output_dir},
        hls_mode: :separate_av,
        mode: :live,
        target_window_duration: Membrane.Time.seconds(20)
      })
    ]

    Zer0Media.WebRTCSignalingRegistry.register(session_id, self())
    Process.send_after(self(), :webrtc_heartbeat_tick, 20_000)

    {[spec: structure],
     %{parent: opts[:parent], output_dir: output_dir, session_id: session_id, viewers: %{}}}
  end

  @impl true
  def handle_info({:add_webrtc_viewer, peer, signaling, viewer_id}, _ctx, state) do
    monitor = Process.monitor(peer)

    viewer = %{
      monitor: monitor,
      viewer_id: viewer_id,
      tracks: [],
      connected?: false,
      audio_linked?: false,
      video_linked?: false
    }

    spec =
      {child({:webrtc, peer}, %Zer0Media.WebRTCBin{
         signaling: signaling,
         video_codec: [:h264],
         ice_ip_filter: &__MODULE__.ice_ip_filter/1
       }), group: {:webrtc_output, peer}, crash_group_mode: :temporary}

    {[spec: spec, notify_child: {{:webrtc, peer}, {:add_tracks, [:audio, :video]}}],
     put_in(state.viewers[peer], viewer)}
  end

  def handle_info({:remove_webrtc_viewer, peer}, _ctx, state), do: remove_viewer(peer, state)

  def handle_info({:DOWN, ref, :process, peer, _reason}, _ctx, state) do
    case state.viewers[peer] do
      %{monitor: ^ref} -> remove_viewer(peer, state)
      _ -> {[], state}
    end
  end

  def handle_info(:webrtc_heartbeat_tick, _ctx, state) do
    for {_peer, viewer} <- state.viewers, viewer.connected? do
      Zer0Media.ViewerTracker.heartbeat(to_string(state.session_id), viewer.viewer_id)
    end

    Process.send_after(self(), :webrtc_heartbeat_tick, 20_000)
    {[], state}
  end

  @impl true
  def handle_child_notification(notification, {:webrtc, peer}, _ctx, state) do
    case state.viewers[peer] do
      nil ->
        {[], state}

      viewer ->
        viewer =
          case notification do
            {:new_tracks, tracks} ->
              %{viewer | tracks: tracks}

            :connected ->
              Zer0Media.ViewerTracker.heartbeat(to_string(state.session_id), viewer.viewer_id)
              %{viewer | connected?: true}

            _ ->
              viewer
          end

        link_webrtc_legs(peer, put_in(state.viewers[peer], viewer))
    end
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  defp link_webrtc_legs(peer, state) do
    viewer = state.viewers[peer]

    {spec, viewer} =
      Enum.reduce(if(viewer.connected?, do: viewer.tracks, else: []), {[], viewer}, fn %{
                                                                                         kind:
                                                                                           kind,
                                                                                         id: id
                                                                                       },
                                                                                       {spec,
                                                                                        viewer} ->
        case {kind, viewer} do
          {:audio, %{audio_linked?: false}} ->
            leg =
              get_child(:audio_tee)
              |> via_out(Pad.ref(:secondary, peer))
              |> child({:audio_parser_webrtc, peer}, %AAC.Parser{out_encapsulation: :ADTS})
              |> child({:aac_decoder, peer}, AAC.FDK.Decoder)
              |> child({:opus_encoder, peer}, %Opus.Encoder{})
              |> via_in(Pad.ref(:input, id), options: [kind: :audio])
              |> get_child({:webrtc, peer})

            {[leg | spec], %{viewer | audio_linked?: true}}

          {:video, %{video_linked?: false}} ->
            leg =
              get_child(:video_tee)
              |> via_out(Pad.ref(:secondary, peer))
              |> child({:video_to_annexb, peer}, %H264.Parser{
                output_stream_structure: :annexb,
                output_alignment: :nalu,
                repeat_parameter_sets: true
              })
              |> via_in(Pad.ref(:input, id), options: [kind: :video])
              |> get_child({:webrtc, peer})

            {[leg | spec], %{viewer | video_linked?: true}}

          _ ->
            {spec, viewer}
        end
      end)

    actions =
      if spec == [],
        do: [],
        else: [spec: {spec, group: {:webrtc_output, peer}, crash_group_mode: :temporary}]

    {actions, put_in(state.viewers[peer], viewer)}
  end

  defp forget_viewer(peer, state) do
    {viewer, viewers} = Map.pop(state.viewers, peer)
    if viewer, do: Process.demonitor(viewer.monitor, [:flush])
    %{state | viewers: viewers}
  end

  defp remove_viewer(peer, state) do
    if Map.has_key?(state.viewers, peer) do
      {[remove_children: {:webrtc_output, peer}], forget_viewer(peer, state)}
    else
      {[], state}
    end
  end

  @impl true
  def handle_crash_group_down({:webrtc_output, peer}, _ctx, state) do
    {[], forget_viewer(peer, state)}
  end

  @impl true
  def handle_child_terminated({:webrtc, peer}, %{exit_reason: :normal} = ctx, state) do
    # A socket DOWN may already have initiated removal of the entire group.
    # Do not submit removal again as each child acknowledges termination.
    if Map.has_key?(state.viewers, peer) do
      remaining =
        for {name, %{group: {:webrtc_output, ^peer}} = child} <- ctx.children,
            not child.terminating?,
            do: name

      actions = if remaining == [], do: [], else: [remove_children: remaining]
      {actions, forget_viewer(peer, state)}
    else
      {[], state}
    end
  end

  def handle_child_terminated(_child, _ctx, state), do: {[], state}

  # ── End-of-stream / cleanup ────────────────────────────────────────────────

  @impl true
  def handle_element_end_of_stream(:hls, _pad, _ctx, state) do
    send(state.parent, {:hls_complete, state.output_dir})
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

  # ── ICE filtering ──────────────────────────────────────────────────────────

  @doc false
  def ice_ip_filter({127, _, _, _}), do: true
  def ice_ip_filter({169, 254, _, _}), do: false
  def ice_ip_filter({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def ice_ip_filter({0xFE, 0x80, _, _, _, _, _, _}), do: false
  def ice_ip_filter({0xFF, _, _, _, _, _, _, _}), do: false
  def ice_ip_filter(_ip), do: true

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp configured_segment_duration do
    case System.get_env("HLS_SEGMENT_DURATION") do
      nil -> Membrane.Time.seconds(1)
      val -> String.to_integer(val)
    end
  end

  defp configured_rate(key, default) do
    value =
      Application.get_env(:zer0_media, key) ||
        System.get_env(key |> Atom.to_string() |> String.upcase())

    case value do
      nil ->
        default

      value when is_number(value) ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _rest} -> parsed
          :error -> default
        end
    end
  end
end
