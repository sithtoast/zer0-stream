defmodule Zer0Media.WebRTCSignalingWebSock do
  @moduledoc """
  WebSocket handler that relays WebRTC signaling messages between a viewer's
  browser and the session's `Membrane.WebRTC.Signaling` channel.

  Serves the same JSON message format as the plugin's built-in
  `SimpleWebSocketServer` (`sdp_offer`, `sdp_answer`, `ice_candidate`, plus a
  periodic `keep_alive`), so the existing frontend `WebRtcPlayer` works
  against the shared origin. An initial `ice_servers` message supplies fresh
  per-viewer browser credentials before SDP negotiation.
  """
  @behaviour WebSock

  require Logger

  alias Membrane.WebRTC.Signaling

  @impl true
  def init(opts) do
    signaling = Signaling.new()
    Process.monitor(signaling.pid)
    Process.monitor(opts.pipeline)
    Signaling.register_peer(signaling, message_format: :json_data)
    send(opts.pipeline, {:add_webrtc_viewer, self(), signaling, opts.viewer_id})
    Process.send_after(self(), :keep_alive, 30_000)
    # Send fresh per-viewer credentials before the queued SDP offer. The
    # stream-level credentials in the control plane may be shared or expired.
    config = %{
      "type" => "ice_servers",
      "data" => Zer0Media.TURN.browser_ice_servers(opts.viewer_id)
    }

    {:push, {:text, Jason.encode!(config)}, %{signaling: signaling, pipeline: opts.pipeline}}
  end

  @impl true
  def handle_in({message, opcode: :text}, state) do
    Signaling.signal(state.signaling, Jason.decode!(message))
    {:ok, state}
  end

  @impl true
  def handle_info({:membrane_webrtc_signaling, _pid, message, _metadata}, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  @impl true
  def handle_info(:keep_alive, state) do
    Process.send_after(self(), :keep_alive, 30_000)
    {:push, {:text, Jason.encode!(%{"type" => "keep_alive", "data" => ""})}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("WebRTC signaling handler ignores unsupported message #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    send(state.pipeline, {:remove_webrtc_viewer, self()})
  end
end
