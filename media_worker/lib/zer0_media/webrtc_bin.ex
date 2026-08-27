defmodule Zer0Media.WebRTCBin do
  @moduledoc """
  Wraps `Membrane.WebRTC.ExWebRTCSink` so it doesn't gate the parent pipeline's
  data flow, and forwards the `:connected` notification so the parent can wait
  until ICE/DTLS is established before linking WebRTC legs.

  Uses ExWebRTCSink directly (instead of WebRTC.Sink) to gain access to the
  `:connected` notification, which WebRTC.Sink consumes internally without
  forwarding. Handles its own connector+RTP-payloader wiring for video tracks
  (the same logic WebRTC.Sink provides).

  Its input pads are dynamic (`on_request`) and are only linked once playback
  starts and tracks are negotiated.
  """
  use Membrane.Bin

  alias Membrane.{Connector, H264, Opus, RTP}
  alias Membrane.WebRTC.ExWebRTCSink

  def_input_pad :input,
    availability: :on_request,
    accepted_format: any_of(%H264{alignment: :nalu}, Opus),
    options: [
      kind: [
        spec: :audio | :video,
        description: "Associates the pad with the negotiated track of the given kind."
      ]
    ]

  def_options signaling: [],
              video_codec: [],
              ice_ip_filter: [default: &__MODULE__.default_ice_ip_filter/1]

  @doc false
  def default_ice_ip_filter(_ip), do: true

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:webrtc, %ExWebRTCSink{
        signaling: opts.signaling,
        tracks: [],
        video_codec: opts.video_codec,
        ice_servers: [%{urls: "stun:stun.l.google.com:19302"}],
        ice_port_range: [0],
        ice_ip_filter: opts.ice_ip_filter
      })

    {[spec: spec], %{video_codec: opts.video_codec}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, pid) = pad_ref, ctx, state) do
    %{kind: kind} = ctx.pad_options

    spec =
      case kind do
        :audio ->
          bin_input(pad_ref)
          |> child({:rtp_opus_payloader, pid}, RTP.Opus.Payloader)
          |> via_in(pad_ref, options: [kind: :audio, codec: :opus])
          |> get_child(:webrtc)

        :video ->
          bin_input(pad_ref)
          |> child({:connector, pad_ref}, %Connector{notify_on_stream_format?: true})
      end

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(
        {:stream_format, _conn_pad, stream_format},
        {:connector, pad_ref},
        _ctx,
        state
      ) do
    payloader =
      case stream_format do
        %H264{} -> %RTP.H264.Payloader{max_payload_size: 1000}
      end

    spec =
      get_child({:connector, pad_ref})
      |> child({:rtp_payloader, pad_ref}, payloader)
      |> via_in(pad_ref, options: [kind: :video, codec: :h264])
      |> get_child(:webrtc)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:connected, :webrtc, _ctx, state) do
    {[notify_parent: :connected], state}
  end

  @impl true
  def handle_child_notification({type, _content} = notification, :webrtc, _ctx, state)
      when type in [:new_tracks, :negotiated_video_codecs] do
    {[notify_parent: notification], state}
  end

  @impl true
  def handle_parent_notification({:add_tracks, tracks}, _ctx, state) do
    {[notify_child: {:webrtc, {:add_tracks, tracks}}], state}
  end
end
