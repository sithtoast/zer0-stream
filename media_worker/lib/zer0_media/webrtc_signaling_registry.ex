defmodule Zer0Media.WebRTCSignalingRegistry do
  @moduledoc "Maps live session IDs to their pipelines, with monitored cleanup."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(session_id, pipeline) do
    GenServer.call(__MODULE__, {:register, session_id, pipeline})
  end

  def lookup(session_id), do: GenServer.call(__MODULE__, {:lookup, session_id})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:register, id, pid}, _from, state) do
    if entry = state[id], do: Process.demonitor(elem(entry, 1), [:flush])
    {:reply, :ok, Map.put(state, id, {pid, Process.monitor(pid)})}
  end

  def handle_call({:lookup, id}, _from, state) do
    pid =
      case state[id] do
        {pid, _ref} -> if Process.alive?(pid), do: pid
        nil -> nil
      end

    {:reply, pid, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, Map.reject(state, fn {_id, {_pid, monitor}} -> monitor == ref end)}
  end
end
