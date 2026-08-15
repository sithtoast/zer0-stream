defmodule Zer0Media.RTMPHandler do
  @behaviour Membrane.RTMPServer.ClientHandler

  require Logger

  alias Membrane.RTMPServer.ClientHandler
  alias Zer0Media.ControlPlane

  @impl true
  def handle_init(%{client_ref: client_ref, connection_id: connection_id, session: session}) do
    ClientHandler.demand_data(client_ref, 1)

    %{client_ref: client_ref, connection_id: connection_id, session: session, bytes: 0}
  end

  @impl true
  def handle_data_available(payload, state) do
    ClientHandler.demand_data(state.client_ref, 1)
    %{state | bytes: state.bytes + byte_size(payload)}
  end

  @impl true
  def handle_delete_stream(state) do
    _ = ControlPlane.stop(state.connection_id)
    state
  end

  @impl true
  def handle_connection_closed(state) do
    _ = ControlPlane.stop(state.connection_id)
    Logger.info("RTMP connection closed: #{state.connection_id}, bytes=#{state.bytes}")
    state
  end

  @impl true
  def handle_info(_message, state), do: state
end
