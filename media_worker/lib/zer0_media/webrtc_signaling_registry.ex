defmodule Zer0Media.WebRTCSignalingRegistry do
  @moduledoc """
  Maps a `session_id` to its `Membrane.WebRTC.Signaling` channel so the shared
  HTTP origin (`HLSRouter`, port 8080) can route a viewer's WebSocket
  connection at `/webrtc/<session_id>` to the right signaling relay.

  Each live pipeline session registers its signaling here when it starts and
  overwrites it on restart. The WebSock handler guards on `Process.alive?/1`
  so a stale entry pointing at a dead signaling is treated as "not found".
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers (or overwrites) the signaling channel for a session."
  def register(session_id, signaling) do
    GenServer.call(__MODULE__, {:register, session_id, signaling})
  end

  @doc "Looks up the signaling channel for a session, or nil if absent/dead."
  def lookup(session_id) do
    case GenServer.call(__MODULE__, {:lookup, session_id}) do
      %{pid: pid} = signaling when is_pid(pid) ->
        if Process.alive?(pid), do: signaling, else: nil

      _ ->
        nil
    end
  end

  @doc "Removes the signaling channel for a session."
  def unregister(session_id) do
    GenServer.call(__MODULE__, {:unregister, session_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:register, session_id, signaling}, _from, state) do
    {:reply, :ok, Map.put(state, session_id, signaling)}
  end

  def handle_call({:lookup, session_id}, _from, state) do
    {:reply, Map.get(state, session_id), state}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    {:reply, :ok, Map.delete(state, session_id)}
  end
end
