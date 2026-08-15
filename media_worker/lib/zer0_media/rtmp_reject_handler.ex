defmodule Zer0Media.RTMPRejectHandler do
  @behaviour Membrane.RTMPServer.ClientHandler

  alias Membrane.RTMPServer.ClientHandler

  @impl true
  def handle_init(%{client_ref: client_ref}) do
    Process.send_after(client_ref, :stop, 0)
    %{client_ref: client_ref}
  end

  @impl true
  def handle_data_available(_payload, state), do: state
  @impl true
  def handle_delete_stream(state), do: state
  @impl true
  def handle_connection_closed(state), do: state
  @impl true
  def handle_info(:stop, %{client_ref: client_ref} = state) do
    ClientHandler.demand_data(client_ref, 0)
    state
  end

  @impl true
  def handle_info(_message, state), do: state
end
