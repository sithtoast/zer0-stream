defmodule Zer0Media.LivePipeline do
  @moduledoc """
  Per-session Membrane pipeline that ingests RTMP and delivers **both** HLS and
  WebRTC from a single source, using `Tee.Master` to split each track.

  HLS uses `Membrane.HTTPAdaptiveStream.SinkBin`. WebRTC uses
  `Membrane.WebRTC.ExWebRTCSink` wrapped in `Zer0Media.WebRTCBin`.

  The `:master` pad drives HLS independently. WebRTC `:copy` pads are only
  linked after the peer connection is fully established (`:connected`
  notification), so the push-mode copy pads never overflow into an incomplete
  sink. The WebRTCBin and its legs live in a temporary crash group so a WebRTC
  failure doesn't take HLS down.
  """
  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.{AAC, H264, Opus, RTMP}
  alias Membrane.HTTPAdaptiveStream

  @impl true
  def handle_init(_ctx, opts) do
    client_ref = Keyword.fetch!(opts, :client_ref)
    output_dir = Keyword.fetch!(opts, :output_dir)
    webrtc_port = Keyword.fetch!(opts, :webrtc_port)

    source = Keyword.get(opts, :source, %RTMP.SourceBin{client_ref: client_ref})

    seg_dur = configured_segment_duration()
    video_scale = configured_rate(:video_timestamp_scale, 0.5)
    audio_rate = configured_rate(:aac_timestamp_rate, 1.008)

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

      # Video: parse H264, correct the publisher's 2x timebase, tee → HLS.
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
      }),

      {child(:webrtc, %Zer0Media.WebRTCBin{
         signaling: {:websocket, [port: webrtc_port]},
         video_codec: [:h264],
         ice_ip_filter: &__MODULE__.ice_ip_filter/1
       }), group: :webrtc_output, crash_group_mode: :temporary}
    ]

    {[spec: structure],
     %{
       parent: opts[:parent],
       output_dir: output_dir,
       webrtc_port: webrtc_port,
       webrtc_tracks: nil,
       webrtc_connected?: false,
       webrtc_audio_linked?: false,
       webrtc_video_linked?: false
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[notify_child: {:webrtc, {:add_tracks, [:audio, :video]}}], state}
  end

  # ── WebRTC signaling ──────────────────────────────────────────────────────

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc, _ctx, state) do
    Membrane.Logger.info("LIVEPIPE negotiated tracks: #{inspect(tracks)}")

    if state.webrtc_connected? do
      link_webrtc_legs(tracks, state)
    else
      {[], %{state | webrtc_tracks: tracks}}
    end
  end

  @impl true
  def handle_child_notification(:connected, :webrtc, _ctx, state) do
    Membrane.Logger.info("LIVEPIPE WebRTC peer connected")

    state = %{state | webrtc_connected?: true}

    if state.webrtc_tracks do
      link_webrtc_legs(state.webrtc_tracks, state)
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(notification, :hls, _ctx, state) do
    Membrane.Logger.info("LIVEPIPE HLS sink notification: #{inspect(notification)}")
    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  defp link_webrtc_legs(tracks, state) do
    {spec, state} =
      Enum.reduce(tracks, {[], state}, fn %{kind: kind, id: id}, {spec, state} ->
        case {kind, state} do
          {:audio, %{webrtc_audio_linked?: false}} ->
            leg =
              get_child(:audio_tee)
              |> via_out(Pad.ref(:secondary, :webrtc))
              |> child(:audio_parser_webrtc, %AAC.Parser{out_encapsulation: :ADTS})
              |> child(:aac_decoder, AAC.FDK.Decoder)
              |> child(:opus_encoder, %Opus.Encoder{})
              |> via_in(Pad.ref(:input, id), options: [kind: :audio])
              |> get_child(:webrtc)

            {[{leg, group: :webrtc_output, crash_group_mode: :temporary} | spec],
             %{state | webrtc_audio_linked?: true}}

          {:video, %{webrtc_video_linked?: false}} ->
            leg =
              get_child(:video_tee)
              |> via_out(Pad.ref(:secondary, :webrtc))
              |> child(:video_to_annexb, %H264.Parser{
                output_stream_structure: :annexb,
                output_alignment: :nalu,
                repeat_parameter_sets: true
              })
              |> via_in(Pad.ref(:input, id), options: [kind: :video])
              |> get_child(:webrtc)

            {[{leg, group: :webrtc_output, crash_group_mode: :temporary} | spec],
             %{state | webrtc_video_linked?: true}}

          _other ->
            {spec, state}
        end
      end)

    if spec == [] do
      {[], state}
    else
      {[spec: spec], %{state | webrtc_tracks: nil}}
    end
  end

  # ── Crash isolation ────────────────────────────────────────────────────────

  @impl true
  def handle_crash_group_down(:webrtc_output, _ctx, state) do
    Membrane.Logger.warning("WebRTC output group went down — restarting")

    spec =
      {child(:webrtc, %Zer0Media.WebRTCBin{
         signaling: {:websocket, [port: state.webrtc_port]},
         video_codec: [:h264],
         ice_ip_filter: &__MODULE__.ice_ip_filter/1
       }), group: :webrtc_output, crash_group_mode: :temporary}

    {[spec: spec, notify_child: {:webrtc, {:add_tracks, [:audio, :video]}}],
     %{state | webrtc_tracks: nil, webrtc_connected?: false, webrtc_audio_linked?: false,
               webrtc_video_linked?: false}}
  end

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
  def ice_ip_filter({0xfe, 0x80, _, _, _, _, _, _}), do: false
  def ice_ip_filter({0xff, _, _, _, _, _, _, _}), do: false
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
