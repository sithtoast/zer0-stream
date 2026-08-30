defmodule Zer0Media.SessionTracker do
  @moduledoc """
  Tracks the set of live RTMP session ids known to this media worker. The RTMP
  client handler registers a session on start and unregisters it on end, and the
  heartbeat reporter uses this set to keep the control plane's staleness clock
  ticking for every live session (independent of viewer count).
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  def touch(session_id), do: GenServer.call(__MODULE__, {:touch, session_id})
  def untouch(session_id), do: GenServer.call(__MODULE__, {:untouch, session_id})
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @impl true
  def handle_call({:touch, session_id}, _from, state) do
    {:reply, :ok, Map.put(state, session_id, true)}
  end

  def handle_call({:untouch, session_id}, _from, state) do
    {:reply, :ok, Map.delete(state, session_id)}
  end

  def handle_call(:sessions, _from, state) do
    {:reply, Map.keys(state), state}
  end
end
