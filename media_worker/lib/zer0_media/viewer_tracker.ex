defmodule Zer0Media.ViewerTracker do
  use GenServer

  @default_ttl_seconds 30
  @default_snapshot_interval_ms 30_000
  @default_average_window_seconds 900

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def heartbeat(stream_id, viewer_id) when is_binary(viewer_id) and viewer_id != "" do
    GenServer.call(__MODULE__, {:heartbeat, to_string(stream_id), viewer_id})
  end

  def count(stream_id) do
    GenServer.call(__MODULE__, {:count, to_string(stream_id)})
  end

  def samples do
    GenServer.call(__MODULE__, :samples)
  end

  def stop(stream_id) do
    GenServer.call(__MODULE__, {:stop, to_string(stream_id)})
  end

  @impl true
  def init(_state) do
    schedule_prune()
    {:ok, %{viewers: %{}, updated_at: %{}, snapshots: %{}}}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{viewers: %{}, updated_at: %{}, snapshots: %{}}}
  end

  @impl true
  def handle_call({:stop, stream_id}, _from, state) do
    viewers =
      Map.reject(state.viewers, fn {{viewer_stream_id, _viewer_id}, _expires_at} ->
        viewer_stream_id == stream_id
      end)

    {:reply, :ok,
     %{
       state
       | viewers: viewers,
         updated_at: Map.delete(state.updated_at, stream_id),
         snapshots: Map.delete(state.snapshots, stream_id)
     }}
  end

  @impl true
  def handle_call({:heartbeat, stream_id, viewer_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    updated_at = DateTime.utc_now() |> DateTime.truncate(:second)
    state = prune_expired(state, now)
    viewers = Map.put(state.viewers, {stream_id, viewer_id}, now + ttl_milliseconds())
    updated_ats = Map.put(state.updated_at, stream_id, updated_at)
    state = %{state | viewers: viewers, updated_at: updated_ats}
    state = record_snapshot(state, stream_id, now)

    {:reply, :ok, state}
  end

  def handle_call({:count, stream_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = prune_expired(state, now)

    viewer_count =
      Enum.count(state.viewers, fn {{viewer_stream_id, _viewer_id}, _expires_at} ->
        viewer_stream_id == stream_id
      end)

    updated_at = Map.get(state.updated_at, stream_id, DateTime.utc_now() |> DateTime.truncate(:second))
    average = average_viewer_count(state, stream_id)

    {:reply, %{viewer_count: viewer_count, updated_at: updated_at, average_viewer_count_15m: average}, state}
  end

  def handle_call(:samples, _from, state) do
    state = prune_expired(state, System.monotonic_time(:millisecond))

    stream_ids =
      Map.keys(state.snapshots) ++
        Enum.map(Map.keys(state.viewers), fn {stream_id, _viewer_id} -> stream_id end)
      |> Enum.uniq()

    samples = Enum.map(stream_ids, &{&1, count_for_stream(state, &1)})
    {:reply, samples, state}
  end

  @impl true
  def handle_info(:prune, state) do
    schedule_prune()
    {:noreply, prune_expired(state, System.monotonic_time(:millisecond))}
  end

  defp prune_expired(state, now) do
    state
    |> Map.update!(:viewers, fn viewers ->
      Map.filter(viewers, fn {_viewer, expires_at} -> expires_at > now end)
    end)
    |> Map.update!(:snapshots, fn snapshots ->
      Enum.reduce(snapshots, %{}, fn {stream_id, samples}, acc ->
        filtered =
          Enum.filter(samples, fn {sample_time, _count} ->
            sample_time > now - average_window_milliseconds()
          end)

        Map.put(acc, stream_id, filtered)
      end)
    end)
  end

  defp record_snapshot(state, stream_id, now) do
    samples = Map.get(state.snapshots, stream_id, [])

    case List.last(samples) do
      nil ->
        put_snapshot(state, stream_id, now, count_for_stream(state, stream_id))

      {last_time, _last_count} ->
        if now - last_time >= snapshot_interval_milliseconds() do
          put_snapshot(state, stream_id, now, count_for_stream(state, stream_id))
        else
          state
        end
    end
  end

  defp put_snapshot(state, stream_id, now, count) do
    samples = Map.get(state.snapshots, stream_id, [])
    filtered = Enum.filter(samples, fn {sample_time, _count} -> sample_time > now - average_window_milliseconds() end)
    updated_samples = filtered ++ [{now, count}]
    %{state | snapshots: Map.put(state.snapshots, stream_id, updated_samples)}
  end

  defp average_viewer_count(state, stream_id) do
    cutoff = System.monotonic_time(:millisecond) - average_window_milliseconds()

    values =
      state.snapshots
      |> Map.get(stream_id, [])
      |> Enum.filter(fn {sample_time, _count} -> sample_time >= cutoff end)
      |> Enum.map(fn {_sample_time, count} -> count end)

    case values do
      [] -> 0.0
      _ -> Enum.sum(values) / length(values)
    end
  end

  defp count_for_stream(state, stream_id) do
    Enum.count(state.viewers, fn {{viewer_stream_id, _viewer_id}, _expires_at} ->
      viewer_stream_id == stream_id
    end)
  end

  defp ttl_milliseconds do
    (Application.get_env(:zer0_media, :viewer_ttl_seconds) ||
       System.get_env("VIEWER_TTL_SECONDS") || @default_ttl_seconds)
    |> parse_positive_integer(@default_ttl_seconds)
    |> Kernel.*(1_000)
  end

  defp snapshot_interval_milliseconds do
    (Application.get_env(:zer0_media, :viewer_snapshot_interval_ms) ||
       System.get_env("VIEWER_SNAPSHOT_INTERVAL_MS") || @default_snapshot_interval_ms)
    |> parse_positive_integer(@default_snapshot_interval_ms)
  end

  defp average_window_milliseconds do
    (Application.get_env(:zer0_media, :viewer_average_window_seconds) ||
       System.get_env("VIEWER_AVERAGE_WINDOW_SECONDS") || @default_average_window_seconds)
    |> parse_positive_integer(@default_average_window_seconds)
    |> Kernel.*(1_000)
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, ttl_milliseconds())

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default
end
