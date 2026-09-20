# Run from media_worker: MIX_ENV=test mix run --no-start bench/llhls_waiters.exs
# Synthetic OTP requests only: no HTTP/TLS, sockets, CMAF or live publisher.
Application.ensure_all_started(:telemetry)

defmodule LLHLSWaiterBench do
  alias Zer0Media.LLHLS.{Playlist, Stream}

  def run(count) do
    {:ok, server} = Stream.start_link(owner: self(), max_waiters: max(count, 5000))
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:zer0_media, :llhls, :wait_start],
        &__MODULE__.registered/4,
        {self(), server}
      )

    parent = self()

    clients =
      for _ <- 1..count do
        spawn_link(fn ->
          send(parent, :spawned)

          receive do
            :begin -> :ok
          end

          result = Stream.await(server, 0, 0)
          send(parent, {:done, match?({:ok, _}, result)})

          receive do
            :timeout_wave -> :ok
          end

          result = Stream.await(server, 0, 1, 1000)
          send(parent, {:expired, result})

          receive do
            :stop -> :ok
          end
        end)
      end

    collect(:spawned, count)
    idle_memory = memory([server | clients])
    Enum.each(clients, &send(&1, :begin))
    collect(:registered, count)
    %{waiters: ^count, targets: 1} = Stream.stats(server)
    blocked_memory = memory([server | clients])
    blocked_mailbox = elem(Process.info(server, :message_queue_len), 1)

    {wake_us, :ok} =
      :timer.tc(fn ->
        :ok = Stream.publish_part(server, 0, 0, 200_000_000, true)
        collect({:done, true}, count)
      end)

    %{waiters: 0, targets: 0} = Stream.stats(server)
    Enum.each(clients, &send(&1, :timeout_wave))

    {timeout_us, :ok} =
      :timer.tc(fn ->
        collect(:registered, count)
        collect({:expired, {:error, :timeout}}, count)
      end)

    %{waiters: 0, targets: 0} = Stream.stats(server)
    :erlang.garbage_collect(server)

    %{memory: remaining, message_queue_len: mailbox} =
      Process.info(server, [:memory, :message_queue_len]) |> Map.new()

    :ok = :telemetry.detach(handler)
    :ok = Stream.stop(server)
    Enum.each(clients, &send(&1, :stop))

    IO.puts(
      Jason.encode!(%{
        viewers: count,
        wake_all_ms: wake_us / 1000,
        blocked_process_bytes_per_viewer: div(blocked_memory, count),
        incremental_blocked_bytes_per_viewer: div(blocked_memory - idle_memory, count),
        registered_mailbox: blocked_mailbox,
        drained_mailbox: mailbox,
        timeout_wave_ms: timeout_us / 1000,
        server_bytes_after_cleanup_gc: remaining
      })
    )
  end

  def registered(_event, _measurements, _metadata, {parent, server}) do
    if self() == server, do: send(parent, :registered)
  end

  def render do
    model =
      Enum.reduce(0..5, Playlist.new(), fn msn, model ->
        model =
          Enum.reduce(0..9, model, fn index, model ->
            {:ok, model} = Playlist.publish_part(model, msn, index, 200_000_000, index == 0)
            model
          end)

        {:ok, model, []} = Playlist.complete_segment(model, msn, 2_000_000_000)
        model
      end)

    opts = [blocking?: true, preload_hint?: true]
    {us, _} = :timer.tc(fn -> for _ <- 1..1000, do: Playlist.render(model, opts) end)

    IO.puts(
      Jason.encode!(%{
        render_us_per_playlist: us / 1000,
        playlist_bytes: byte_size(Playlist.render(model, opts)),
        completed_segments: 6,
        parts: 60
      })
    )
  end

  defp memory(pids),
    do: Enum.reduce(pids, 0, fn pid, total -> total + elem(Process.info(pid, :memory), 1) end)

  defp collect(_message, 0), do: :ok

  defp collect(message, count) do
    receive do
      ^message -> collect(message, count - 1)
    after
      15_000 -> raise "benchmark timed out waiting for #{inspect(message)} (#{count} remaining)"
    end
  end
end

IO.puts(
  Jason.encode!(%{
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online()
  })
)

Enum.each([100, 1000, 5000], &LLHLSWaiterBench.run/1)
LLHLSWaiterBench.render()
