defmodule Zer0Media.LLHLS.Stream do
  @moduledoc """
  One temporary OTP process per stream generation and rendition. The publisher
  is monitored; a failed publisher drains requests and ends this incarnation.
  A reconnect must use a new process and a new generation in the media URL.

  Waiters are grouped by requested MSN/part, monitored, capped and timed out.
  A publication evaluates each distinct target once, renders once, and replies
  with a shared binary. No media bytes or HTTP connections live in this process.
  The opt-in origin serves these snapshots after atomic CMAF publication.
  """
  use GenServer, restart: :temporary
  alias Zer0Media.LLHLS.Playlist

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def publish_part(server, msn, index, duration, independent? \\ false),
    do: GenServer.call(server, {:part, msn, index, duration, independent?})

  def complete_segment(server, msn, duration),
    do: GenServer.call(server, {:segment, msn, duration})

  def finish(server), do: GenServer.call(server, :finish)
  def stats(server), do: GenServer.call(server, :stats)
  def stop(server), do: GenServer.call(server, :stop)

  @doc "Wait without polling; timeout is owned by the server and capped at three target durations."
  def await(server, msn \\ nil, part \\ nil, timeout_ms \\ :default) do
    GenServer.call(server, {:await, msn, part, timeout_ms}, :infinity)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def await_part(server, msn, part, timeout_ms \\ :default) do
    GenServer.call(server, {:await_part, msn, part, timeout_ms}, :infinity)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    model = Playlist.new(Keyword.get(opts, :playlist, []))
    max_waiters = Keyword.get(opts, :max_waiters, 5000)

    unless is_pid(owner) and is_integer(max_waiters) and max_waiters in 1..100_000,
      do: raise(ArgumentError, "owner PID and bounded max_waiters required")

    render_opts = Keyword.get(opts, :render, [])

    {:ok,
     %{
       model: model,
       require_media?: Keyword.get(opts, :require_media?, false),
       playlist: Playlist.render(model, render_opts),
       render_opts: render_opts,
       owner_ref: Process.monitor(owner),
       waiters: %{},
       buckets: %{},
       max_waiters: max_waiters,
       timeout_ms: div(3 * model.target_duration, 1_000_000)
     }}
  end

  @impl true
  def handle_call({:await, msn, part, timeout}, from, state),
    do: reply_or_wait(state, from, {:playlist, msn, part}, timeout)

  def handle_call({:await_part, msn, part, timeout}, from, state),
    do: reply_or_wait(state, from, {:part, msn, part}, timeout)

  def handle_call({:part, msn, index, duration, independent?}, _from, state) do
    case Playlist.publish_part(state.model, msn, index, duration, independent?) do
      {:ok, model} ->
        emit(:part, %{count: 1, duration: duration}, %{})
        {:reply, :ok, publish(state, model)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:segment, msn, duration}, _from, state) do
    case Playlist.complete_segment(state.model, msn, duration) do
      {:ok, model, evicted} ->
        emit(:segment, %{count: 1, duration: duration, evicted: length(evicted)}, %{})
        {:reply, {:ok, evicted}, publish(state, model)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:finish, _from, state) do
    case Playlist.finish(state.model) do
      {:ok, model} ->
        if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
        {:reply, :ok, publish(%{state | owner_ref: nil}, model)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       waiters: map_size(state.waiters),
       targets: map_size(state.buckets),
       segments: length(state.model.segments),
       parts: length(state.model.parts)
     }, state}
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, drain(state, :terminated)}

  @impl true
  def handle_info({:wait_timeout, ref}, state),
    do: {:noreply, release(state, ref, {:error, :timeout}, :timeout)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    emit(:publisher_down, %{count: 1}, %{})
    {:stop, :normal, drain(state, :publisher_down)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, release(state, ref, nil, :cancelled)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    drain(state, :terminated)
    :ok
  end

  defp publish(state, model) do
    started = System.monotonic_time()
    state = %{state | model: model, playlist: Playlist.render(model, state.render_opts)}

    emit(
      :render,
      %{duration: System.monotonic_time() - started, bytes: byte_size(state.playlist)},
      %{}
    )

    Enum.reduce(state.buckets, state, fn {key, refs}, acc ->
      case availability(state, key) do
        :wait -> acc
        :ready -> Enum.reduce(refs, acc, &release(&2, &1, response(acc, key), :published))
        {:error, reason} -> Enum.reduce(refs, acc, &release(&2, &1, {:error, reason}, reason))
      end
    end)
  end

  defp reply_or_wait(state, from, key, timeout) do
    timeout = if timeout == :default, do: state.timeout_ms, else: timeout

    case availability(state, key) do
      :ready ->
        {:reply, response(state, key), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :wait ->
        cond do
          not is_integer(timeout) or timeout <= 0 or timeout > state.timeout_ms ->
            {:reply, {:error, :invalid_timeout}, state}

          map_size(state.waiters) >= state.max_waiters ->
            emit(:rejected, %{count: 1}, %{reason: :capacity})
            {:reply, {:error, :capacity}, state}

          true ->
            ref = Process.monitor(elem(from, 0))
            timer = Process.send_after(self(), {:wait_timeout, ref}, timeout)
            waiter = %{from: from, timer: timer, key: key, started: System.monotonic_time()}
            buckets = Map.update(state.buckets, key, MapSet.new([ref]), &MapSet.put(&1, ref))
            state = %{state | waiters: Map.put(state.waiters, ref, waiter), buckets: buckets}
            emit(:wait_start, %{count: 1, active: map_size(state.waiters)}, %{})
            {:noreply, state}
        end
    end
  end

  defp availability(
         %{require_media?: true, model: %{parts: [], segments: [], ended?: false}},
         {:playlist, nil, nil}
       ),
       do: :wait

  defp availability(state, {:playlist, msn, part}),
    do: Playlist.availability(state.model, msn, part)

  defp availability(state, {:part, msn, part}),
    do: Playlist.part_availability(state.model, msn, part)

  defp response(state, {:playlist, _, _}), do: {:ok, state.playlist}
  defp response(_state, {:part, _, _}), do: {:ok, :available}

  defp release(state, ref, reply, outcome) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        state

      {waiter, waiters} ->
        Process.cancel_timer(waiter.timer)
        Process.demonitor(ref, [:flush])
        if reply, do: GenServer.reply(waiter.from, reply)
        refs = state.buckets[waiter.key] |> MapSet.delete(ref)

        buckets =
          if MapSet.size(refs) == 0,
            do: Map.delete(state.buckets, waiter.key),
            else: Map.put(state.buckets, waiter.key, refs)

        emit(
          :wait_stop,
          %{
            duration: System.monotonic_time() - waiter.started,
            active: map_size(waiters),
            count: 1
          },
          %{outcome: outcome}
        )

        %{state | waiters: waiters, buckets: buckets}
    end
  end

  defp drain(state, reason),
    do: Enum.reduce(Map.keys(state.waiters), state, &release(&2, &1, {:error, reason}, reason))

  defp emit(event, measurements, metadata),
    do: :telemetry.execute([:zer0_media, :llhls, event], measurements, metadata)
end
