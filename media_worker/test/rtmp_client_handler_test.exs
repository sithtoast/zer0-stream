defmodule Zer0Media.RTMPClientHandlerTest.ControlPlaneStub do
  def init(parent), do: parent

  def call(conn, parent) do
    send(parent, {:control_plane_request, conn.request_path})
    Plug.Conn.send_resp(conn, 200, "ok")
  end
end

defmodule Zer0Media.RTMPClientHandlerTest do
  use ExUnit.Case, async: false
  alias Zer0Media.{RTMPClientHandler, SessionTracker, ViewerTracker}

  test "pipeline loss ends accounting once and cannot resume ingest after a late source message" do
    server = start_supervised!({Bandit, plug: {__MODULE__.ControlPlaneStub, self()}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    previous = Application.get_env(:zer0_media, :control_plane_url)
    Application.put_env(:zer0_media, :control_plane_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zer0_media, :control_plane_url, previous),
        else: Application.delete_env(:zer0_media, :control_plane_url)
    end)

    session = System.unique_integer([:positive])

    pipeline =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state =
      RTMPClientHandler.handle_init(%{
        client_ref: self(),
        connection_id: "fixture",
        session_id: session,
        live_pipeline_pid: pipeline
      })

    assert_receive {:demand_data, 1}
    assert session in SessionTracker.sessions()
    ViewerTracker.heartbeat(to_string(session), "fixture")
    assert ViewerTracker.count(to_string(session)).viewer_count == 1
    send(pipeline, :stop)
    ref = state.pipeline_ref
    assert_receive {:DOWN, ^ref, :process, ^pipeline, :normal} = down
    state = RTMPClientHandler.handle_info(down, state)
    assert state.ended?
    assert_receive {:demand_data, 0}
    assert_receive {:control_plane_request, "/api/ingest/rtmp/fixture/stop"}
    refute session in SessionTracker.sessions()
    assert ViewerTracker.count(to_string(session)).viewer_count == 0
    assert RTMPClientHandler.handle_connection_closed(state) == state
    assert RTMPClientHandler.handle_info({:send_me_data, self()}, state) == state
    assert RTMPClientHandler.handle_data_available("late bytes", state) == state
    refute_receive {:demand_data, 1}
    refute_receive {:control_plane_request, _}
  end
end
