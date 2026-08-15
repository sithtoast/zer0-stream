defmodule Zer0Media.RTMPClientHandler do
  @behaviour Membrane.RTMPServer.ClientHandler

  alias Membrane.RTMPServer.ClientHandler
  alias Zer0Media.ControlPlane

  @impl true
  def handle_init(opts) do
    ClientHandler.demand_data(opts.client_ref, 1)

    %{
      client_ref: opts.client_ref,
      source_pid: nil,
      buffered: [],
      connection_id: opts.connection_id,
      boombox_pid: opts[:boombox_pid]
    }
  end

  @impl true
  def handle_info({:send_me_data, source_pid}, state) do
    state = %{state | source_pid: source_pid}
    Enum.each(Enum.reverse(state.buffered), &send_data(source_pid, &1))
    ClientHandler.demand_data(state.client_ref, 1)
    %{state | buffered: []}
  end

  @impl true
  def handle_info(_other, state), do: state

  @impl true
  def handle_data_available(payload, %{source_pid: source_pid} = state)
      when is_pid(source_pid) do
    :ok = send_data(source_pid, payload)
    ClientHandler.demand_data(state.client_ref, 1)
    state
  end

  def handle_data_available(payload, state), do: %{state | buffered: [payload | state.buffered]}

  @impl true
  def handle_connection_closed(state) do
    stop_session(state)
    state
  end

  @impl true
  def handle_delete_stream(state) do
    stop_session(state)
    state
  end

  defp stop_session(state) do
    _ = ControlPlane.stop(state.connection_id)

    if state.boombox_pid do
      Zer0Media.BoomboxSessionSupervisor.stop_session(state.boombox_pid)
    end
  end

  defp send_data(pid, payload) do
    send(pid, {:data, payload})
    :ok
  end
end
