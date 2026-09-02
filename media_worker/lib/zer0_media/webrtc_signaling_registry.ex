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

  @doc """
  Records the viewer_id (derived from the same playback token used for HLS)
  for the viewer currently connecting to a session's WebRTC signaling socket.

  This lets `Zer0Media.LivePipeline`'s WebRTC heartbeat use the SAME viewer_id
  the viewer's HLS requests would use, so a viewer who is briefly on both
  transports (e.g. HLS fallback while WebRTC reconnects) is counted once
  instead of twice.
  """
  def set_viewer_id(session_id, viewer_id) do
    GenServer.call(__MODULE__, {:set_viewer_id, session_id, viewer_id})
  end

  @doc "Looks up the viewer_id recorded for a session, or nil if absent."
  def get_viewer_id(session_id) do
    GenServer.call(__MODULE__, {:get_viewer_id, session_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{signalings: %{}, viewer_ids: %{}}}

  @impl true
  def handle_call({:register, session_id, signaling}, _from, state) do
    {:reply, :ok, put_in(state.signalings[session_id], signaling)}
  end

  def handle_call({:lookup, session_id}, _from, state) do
    {:reply, Map.get(state.signalings, session_id), state}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    state =
      state
      |> update_in([:signalings], &Map.delete(&1, session_id))
      |> update_in([:viewer_ids], &Map.delete(&1, session_id))

    {:reply, :ok, state}
  end

  def handle_call({:set_viewer_id, session_id, viewer_id}, _from, state) do
    {:reply, :ok, put_in(state.viewer_ids[session_id], viewer_id)}
  end

  def handle_call({:get_viewer_id, session_id}, _from, state) do
    {:reply, Map.get(state.viewer_ids, session_id), state}
  end
end
