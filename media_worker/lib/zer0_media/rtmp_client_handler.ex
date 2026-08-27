defmodule Zer0Media.RTMPClientHandler do
  @behaviour Membrane.RTMPServer.ClientHandler

  alias Membrane.RTMPServer.ClientHandler
  alias Zer0Media.ControlPlane

  @default_idle_timeout_ms 15_000

  @impl true
  def handle_init(opts) do
    ClientHandler.demand_data(opts.client_ref, 1)

    %{
      client_ref: opts.client_ref,
      source_pid: nil,
      buffered: [],
      connection_id: opts.connection_id,
      session_id: opts.session_id,
      boombox_pid: opts[:boombox_pid],
      live_pipeline_pid: opts[:live_pipeline_pid],
      webrtc_port: opts[:webrtc_port],
      hls_output_dir: opts[:hls_output_dir],
      idle_timer: nil,
      ended?: false
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
  def handle_info(:stream_idle, %{ended?: false} = state) do
    stop_session(state)
    ClientHandler.demand_data(state.client_ref, 0)
    %{state | ended?: true, idle_timer: nil}
  end

  def handle_info(:stream_idle, state), do: state

  @impl true
  def handle_info(_other, state), do: state

  @impl true
  def handle_data_available(_payload, %{ended?: true} = state), do: state

  def handle_data_available(payload, %{source_pid: source_pid} = state)
      when is_pid(source_pid) do
    :ok = send_data(source_pid, payload)
    ClientHandler.demand_data(state.client_ref, 1)
    reset_idle_timer(state)
  end

  def handle_data_available(payload, state) do
    state
    |> Map.update!(:buffered, &[payload | &1])
    |> reset_idle_timer()
  end

  @impl true
  def handle_connection_closed(state) do
    end_session(state)
  end

  @impl true
  def handle_delete_stream(state) do
    end_session(state)
  end

  defp stop_session(state) do
    _ = ControlPlane.stop(state.connection_id)
    Zer0Media.ViewerTracker.stop(state.session_id)

    if state.boombox_pid do
      Zer0Media.BoomboxSessionSupervisor.stop_session(state.boombox_pid)
    end

    if state.live_pipeline_pid do
      Membrane.Pipeline.terminate(state.live_pipeline_pid)
    end

    if state.hls_output_dir do
      Zer0Media.HLSCleanup.schedule(state.hls_output_dir)
    end
  end

  defp send_data(pid, payload) do
    send(pid, {:data, payload})
    :ok
  end

  defp end_session(%{ended?: true} = state), do: state

  defp end_session(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    stop_session(state)
    %{state | ended?: true, idle_timer: nil}
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = Process.send_after(state.client_ref, :stream_idle, idle_timeout_milliseconds())
    %{state | idle_timer: timer}
  end

  defp idle_timeout_milliseconds do
    value =
      Application.get_env(:zer0_media, :rtmp_idle_timeout_ms) ||
        System.get_env("RTMP_IDLE_TIMEOUT_MS")

    case value do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _other -> @default_idle_timeout_ms
        end

      _other ->
        @default_idle_timeout_ms
    end
  end
end
