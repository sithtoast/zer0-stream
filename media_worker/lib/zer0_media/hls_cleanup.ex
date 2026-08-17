defmodule Zer0Media.HLSCleanup do
  use GenServer

  require Logger

  @session_directory_prefix "stream-session-"
  @default_grace_ms 60_000

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: Keyword.get(init_arg, :name, __MODULE__))
  end

  def schedule(directory) when is_binary(directory) do
    GenServer.cast(__MODULE__, {:schedule, directory})
  end

  @impl true
  def init(_init_arg) do
    purge_stale_sessions()
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_cast({:schedule, directory}, state) do
    case Map.pop(state.timers, directory) do
      {nil, timers} ->
        schedule_cleanup(directory, timers)

      {timer, timers} ->
        Process.cancel_timer(timer)
        schedule_cleanup(directory, timers)
    end
  end

  @impl true
  def handle_info({:cleanup, directory}, state) do
    Logger.info("Removing expired HLS artifacts from #{directory}")
    File.rm_rf(directory)
    {:noreply, %{state | timers: Map.delete(state.timers, directory)}}
  end

  defp schedule_cleanup(directory, timers) do
    timer = Process.send_after(self(), {:cleanup, directory}, cleanup_grace_ms())
    {:noreply, %{timers: Map.put(timers, directory, timer)}}
  end

  defp purge_stale_sessions do
    hls_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "#{@session_directory_prefix}*")))
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(fn directory ->
      Logger.info("Removing stale HLS artifacts from #{directory}")
      File.rm_rf(directory)
    end)
  end

  defp hls_roots do
    [
      Application.get_env(:zer0_media, :hls_dir, "priv/hls"),
      Application.get_env(:zer0_media, :boombox_hls_dir, "priv/hls-boombox")
    ]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp cleanup_grace_ms do
    value =
      Application.get_env(:zer0_media, :hls_cleanup_grace_ms) ||
        System.get_env("HLS_CLEANUP_GRACE_MS")

    case value do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _other -> @default_grace_ms
        end

      _other ->
        @default_grace_ms
    end
  end
end