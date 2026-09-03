defmodule Zer0Media.WebRTCSignalingWebSock do
  @moduledoc """
  WebSocket handler that relays WebRTC signaling messages between a viewer's
  browser and the session's `Membrane.WebRTC.Signaling` channel.

  Serves the same JSON message format as the plugin's built-in
  `SimpleWebSocketServer` (`sdp_offer`, `sdp_answer`, `ice_candidate`, plus a
  periodic `keep_alive`), so the existing frontend `WebRtcPlayer` works
  unchanged against the shared origin.
  """
  @behaviour WebSock

  require Logger

  alias Membrane.WebRTC.Signaling

  @impl true
  def init(opts) do
    signaling = opts.signaling
    Signaling.register_peer(signaling, message_format: :json_data)
    Process.send_after(self(), :keep_alive, 30_000)
    {:ok, %{signaling: signaling, session_id: opts.session_id}}
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
  def handle_info(message, state) do
    Logger.debug("WebRTC signaling handler ignores unsupported message #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Zer0Media.WebRTCSignalingRegistry.release_viewer(state.session_id)
  end
end
