defmodule Zer0Media.RTMPServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  setup do
    server =
      start_supervised!(%{
        id: :rtmp_server,
        start:
          {Membrane.RTMPServer, :start_link,
           [[port: 0, handle_new_client: fn _, _, _ -> raise "unexpected publish" end]]}
      })

    %{server: server, port: Membrane.RTMPServer.get_port(server)}
  end

  test "HTTP on the RTMP port closes only that client and does not log the payload", ctx do
    healthy = connect(ctx.port)
    handshake(healthy)
    [healthy_pid] = clients(ctx.server)

    log =
      capture_log(fn ->
        bad = connect(ctx.port)
        payload = "POST / HTTP/1.1\r\n\r\nprivate-payload-marker" <> String.duplicate("x", 1600)
        :ok = :gen_tcp.send(bad, payload)
        assert {:error, :closed} = :gen_tcp.recv(bad, 0, 2000)
      end)

    assert log =~ "Closing RTMP client: invalid packet"
    refute log =~ "private-payload-marker"
    assert Process.alive?(ctx.server)
    assert Process.alive?(healthy_pid)
    assert {:error, :timeout} = :gen_tcp.recv(healthy, 0, 50)
    handshake(connect(ctx.port))
  end

  test "an unexpected client crash leaves the listener and other clients running", ctx do
    handshake(connect(ctx.port))
    [healthy_pid] = clients(ctx.server)
    handshake(connect(ctx.port))
    [crashing_pid] = clients(ctx.server) -- [healthy_pid]
    monitor = Process.monitor(crashing_pid)
    Process.exit(crashing_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^crashing_pid, :killed}
    assert Process.alive?(ctx.server)
    assert Process.alive?(healthy_pid)
    handshake(connect(ctx.port))
    refute crashing_pid in clients(ctx.server)
  end

  test "closing a socket stops its client process", ctx do
    socket = connect(ctx.port)
    handshake(socket)
    [client] = clients(ctx.server)
    monitor = Process.monitor(client)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  test "stopping the server also stops its clients", ctx do
    handshake(connect(ctx.port))
    [client] = clients(ctx.server)
    monitor = Process.monitor(client)
    stop_supervised!(:rtmp_server)
    assert_receive {:DOWN, ^monitor, :process, ^client, _reason}
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp handshake(socket) do
    {step, state} = Membrane.RTMP.Handshake.init_client(0)
    :ok = :gen_tcp.send(socket, Membrane.RTMP.Handshake.Step.serialize(step))
    {:ok, response} = :gen_tcp.recv(socket, 3073, 2000)

    assert {:handshake_finished, reply, _state} =
             Membrane.RTMP.Handshake.handle_step(response, state)

    :ok = :gen_tcp.send(socket, Membrane.RTMP.Handshake.Step.serialize(reply))
  end

  defp clients(server) do
    %{client_supervisor: supervisor} = :sys.get_state(server)
    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor), do: pid
  end
end
