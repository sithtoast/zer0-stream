defmodule Zer0Media.LLHLS.StreamTest do
  use ExUnit.Case, async: true
  alias Zer0Media.LLHLS.Stream
  @part 200_000_000

  defp start_stream(opts \\ []) do
    start_supervised!({Stream, Keyword.merge([owner: self()], opts)})
  end

  # OTP asynchronous calls plus a same-sender stats barrier make registration
  # deterministic, without sleeps/polling or a browser.
  defp request(server, msn, part \\ nil, timeout \\ :default),
    do: :gen_server.send_request(server, {:await, msn, part, timeout})

  defp response(ref), do: :gen_server.receive_response(ref, 2000)

  test "a new part wakes all viewers for the same target with one shared playlist" do
    server = start_stream()
    requests = for _ <- 1..1000, do: request(server, 0, 0)
    assert %{waiters: 1000, targets: 1} = Stream.stats(server)
    :ok = Stream.publish_part(server, 0, 0, @part, true)

    bodies =
      for ref <- requests do
        assert {:reply, {:ok, body}} = response(ref)
        body
      end

    assert length(Enum.uniq(bodies)) == 1
    assert hd(bodies) =~ "part-0-0.m4s"
    assert %{waiters: 0, targets: 0} = Stream.stats(server)
    assert {:message_queue_len, 0} = Process.info(server, :message_queue_len)
  end

  test "part publication does not satisfy segment-only or later-part requests" do
    server = start_stream()
    first = request(server, 0, 0)
    later = request(server, 0, 1)
    segment = request(server, 0)
    assert %{waiters: 3, targets: 3} = Stream.stats(server)
    :ok = Stream.publish_part(server, 0, 0, @part)
    assert {:reply, {:ok, _}} = response(first)
    assert %{waiters: 2} = Stream.stats(server)
    :ok = Stream.publish_part(server, 0, 1, @part)
    assert {:reply, {:ok, _}} = response(later)
    assert %{waiters: 1} = Stream.stats(server)
    assert {:ok, []} = Stream.complete_segment(server, 0, 2 * @part)
    assert {:reply, {:ok, body}} = response(segment)
    assert body =~ "segment-0.m4s"
  end

  test "available requests bypass waiter capacity; future requests fail fast" do
    server = start_stream(max_waiters: 1)
    first = request(server, 0, 0)
    assert %{waiters: 1} = Stream.stats(server)
    assert {:error, :capacity} = Stream.await(server, 0, 0)
    assert {:ok, _} = Stream.await(server)
    assert {:error, :too_far_ahead} = Stream.await(server, 99)
    assert {:error, :part_without_msn} = Stream.await(server, nil, 0)
    :ok = Stream.publish_part(server, 0, 0, @part)
    assert {:reply, {:ok, _}} = response(first)
    assert {:ok, _} = Stream.await(server, 0, 0)
    assert %{waiters: 0} = Stream.stats(server)
  end

  test "timeout cleanup is idempotent when publication races an already queued timer" do
    server = start_stream()
    expired = request(server, 0, 0)
    assert %{waiters: 1} = Stream.stats(server)
    [ref] = Map.keys(:sys.get_state(server).waiters)
    send(server, {:wait_timeout, ref})
    assert {:reply, {:error, :timeout}} = response(expired)
    send(server, {:wait_timeout, ref})
    :ok = Stream.publish_part(server, 0, 0, @part)
    assert %{waiters: 0, targets: 0} = Stream.stats(server)
    ready = request(server, 0, 1)
    assert %{waiters: 1} = Stream.stats(server)
    [ref] = Map.keys(:sys.get_state(server).waiters)
    :ok = Stream.publish_part(server, 0, 1, @part)
    send(server, {:wait_timeout, ref})
    assert {:reply, {:ok, _}} = response(ready)
    assert %{waiters: 0, targets: 0} = Stream.stats(server)
  end

  test "real deadline fires and invalid timeouts cannot pin requests" do
    server = start_stream()
    assert {:error, :invalid_timeout} = Stream.await(server, 0, 0, 0)
    assert {:error, :invalid_timeout} = Stream.await(server, 0, 0, 6001)
    assert {:error, :timeout} = Stream.await(server, 0, 0, 10)
    assert %{waiters: 0, targets: 0} = Stream.stats(server)
  end

  test "caller death removes the monitor, timer and target" do
    server = start_stream()
    parent = self()

    caller =
      spawn(fn ->
        _ref = request(server, 0, 0)
        send(parent, {:registered, Stream.stats(server)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, %{waiters: 1}}
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:zer0_media, :llhls, :wait_stop],
        &__MODULE__.wait_stopped/4,
        {self(), server}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    mon = Process.monitor(caller)
    send(caller, :stop)
    assert_receive {:DOWN, ^mon, :process, ^caller, :normal}
    assert_receive {:wait_stopped, :cancelled, %{active: 0, count: 1}}
    assert %{waiters: 0, targets: 0} = Stream.stats(server)
    refute Enum.any?(elem(Process.info(server, :monitors), 1), &(&1 == {:process, caller}))
  end

  test "publisher failure drains waiters and a fresh incarnation starts at sequence zero" do
    publisher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    server = start_stream(owner: publisher)
    pending = request(server, 0, 0)
    assert %{waiters: 1} = Stream.stats(server)
    monitor = Process.monitor(server)
    send(publisher, :stop)
    assert {:reply, {:error, :publisher_down}} = response(pending)
    assert_receive {:DOWN, ^monitor, :process, ^server, reason}
    assert reason in [:normal, :noproc]
    assert {:error, :unavailable} = Stream.await(server, 0)
    assert Stream.child_spec(owner: self()).restart == :temporary
    stop_supervised(Stream)
    fresh = start_stream()
    {:ok, body} = Stream.await(fresh)
    assert body =~ "#EXT-X-MEDIA-SEQUENCE:0"
    refute body =~ "#EXT-X-PART:DURATION"
  end

  test "graceful finish answers pending requests with ENDLIST; explicit stop drains" do
    server = start_stream()
    pending = request(server, 1, 0)
    :ok = Stream.finish(server)
    assert {:reply, {:ok, body}} = response(pending)
    assert body =~ "#EXT-X-ENDLIST"
    assert {:ok, ^body} = Stream.await(server, 10_000, 10_000)
    assert :ok = Stream.stop(server)
    stop_supervised(Stream)
    server = start_stream()
    pending = request(server, 0, 0)
    :ok = Stream.stop(server)
    assert {:reply, {:error, :terminated}} = response(pending)
  end

  test "finalized state remains readable when the publisher exits" do
    publisher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    server = start_stream(owner: publisher)
    assert {:ok, []} = Stream.complete_segment(server, 0, @part)
    old_owner_ref = :sys.get_state(server).owner_ref
    :ok = Stream.finish(server)
    send(publisher, :stop)
    # A DOWN already in flight cannot undo a successfully finalized snapshot.
    send(server, {:DOWN, old_owner_ref, :process, publisher, :normal})
    assert {:ok, body} = Stream.await(server, 100, 100)
    assert body =~ "#EXT-X-ENDLIST"
    assert Process.alive?(server)
    assert :ok = Stream.finish(server)
  end

  test "shutdown releases outstanding calls" do
    server = start_stream()
    pending = request(server, 0, 0)
    assert %{waiters: 1} = Stream.stats(server)
    stop_supervised(Stream)
    assert {:reply, {:error, :terminated}} = response(pending)
  end

  test "independent renditions do not cross-wake each other's viewers" do
    video = start_stream()
    audio = start_supervised!(Supervisor.child_spec({Stream, owner: self()}, id: :audio))
    v = request(video, 0, 0)
    a = request(audio, 0, 0)
    :ok = Stream.publish_part(video, 0, 0, @part)
    assert {:reply, {:ok, _}} = response(v)
    assert %{waiters: 1} = Stream.stats(audio)
    :ok = Stream.publish_part(audio, 0, 0, @part)
    assert {:reply, {:ok, _}} = response(a)
  end

  def wait_stopped(_event, measurements, metadata, {parent, server}) do
    if self() == server, do: send(parent, {:wait_stopped, metadata.outcome, measurements})
  end
end
