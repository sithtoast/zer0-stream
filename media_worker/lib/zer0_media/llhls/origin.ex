defmodule Zer0Media.LLHLS.Origin do
  @moduledoc "Generation discovery, lifecycle and delayed object reclamation."
  use GenServer
  alias Zer0Media.LLHLS.{Generation, Stream}
  @registry Zer0Media.LLHLS.Registry
  @supervisor Zer0Media.LLHLS.Supervisor

  def via(key), do: {:via, Registry, {@registry, key}}

  def lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start_generation(session, owner, legacy_directory, config) do
    session = to_string(session)

    unless Regex.match?(~r/\A[0-9]+\z/, session),
      do: raise(ArgumentError, "numeric session required")

    generation = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Application.get_env(:zer0_media, :llhls_dir, "priv/llhls")
    directory = Path.expand(Path.join([root, "stream-session-#{session}", generation]))

    opts = [
      session: session,
      generation: generation,
      owner: owner,
      directory: directory,
      legacy_directory: Path.expand(legacy_directory),
      config: config
    ]

    case DynamicSupervisor.start_child(@supervisor, {Generation, opts}) do
      {:ok, _sup} -> {:ok, lookup({session, generation, :origin})}
      error -> error
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: via({opts[:session], opts[:generation], :origin})
    )
  end

  def info(server), do: GenServer.call(server, :info)
  def track(server, rendition), do: GenServer.call(server, {:track, to_string(rendition)})
  def published(server, rendition), do: GenServer.call(server, {:published, to_string(rendition)})
  def master(server, body), do: GenServer.call(server, {:master, body})
  def finish_track(server, rendition), do: GenServer.call(server, {:finish, to_string(rendition)})
  def retire(server, paths), do: GenServer.call(server, {:retire, paths})

  def current(session) do
    Registry.select(@registry, [{{{session, :_, :origin}, :"$1", :"$2"}, [], [{{:"$2", :"$1"}}]}])
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_stamp, pid} -> pid
    end
  end

  @impl true
  def init(opts) do
    state = Map.new(opts)
    File.mkdir_p!(state.directory)

    Registry.update_value(@registry, {state.session, state.generation, :origin}, fn _ ->
      System.unique_integer([:positive, :monotonic])
    end)

    tracks =
      Map.new(state.config.renditions, fn rendition ->
        pid = lookup({state.session, state.generation, rendition})
        {rendition, %{pid: pid, ref: Process.monitor(pid)}}
      end)

    {:ok,
     Map.merge(state, %{
       tracks: tracks,
       owner_ref: Process.monitor(state.owner),
       ready: MapSet.new(),
       finished: MapSet.new(),
       master: nil,
       status: :live,
       cleanup_timer: nil,
       retired: %{}
     })}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     Map.take(state, [:session, :generation, :directory, :master, :status])
     |> Map.put(:ready?, MapSet.size(state.ready) == map_size(state.tracks)), state}
  end

  def handle_call({:track, rendition}, _from, state) do
    case {state.status, state.tracks[rendition]} do
      {:failed, _} ->
        {:reply, {:error, :unavailable}, state}

      {_, nil} ->
        {:reply, {:error, :not_found}, state}

      {_, %{pid: pid}} ->
        {:reply, {:ok, pid, Path.join(state.directory, rendition)}, state}
    end
  end

  def handle_call({:published, rendition}, _from, state),
    do: {:reply, :ok, %{state | ready: MapSet.put(state.ready, rendition)}}

  def handle_call({:master, body}, _from, state) do
    body =
      Enum.reduce(state.config.renditions, body, fn name, body ->
        body
        |> String.replace("URI=\"#{name}.m3u8\"", "URI=\"#{name}/index.m3u8\"")
        |> String.split("\n")
        |> Enum.map(fn line ->
          if line == "#{name}.m3u8", do: "#{name}/index.m3u8", else: line
        end)
        |> Enum.join("\n")
      end)

    {:reply, :ok, %{state | master: body}}
  end

  def handle_call({:finish, rendition}, _from, state) do
    finished = MapSet.put(state.finished, rendition)
    status = if MapSet.size(finished) == map_size(state.tracks), do: :ended, else: state.status
    state = %{state | finished: finished, status: status}
    {:reply, :ok, if(status == :ended, do: schedule_cleanup(state), else: state)}
  end

  def handle_call({:retire, paths}, _from, state) do
    valid? =
      Enum.all?(paths, fn path ->
        expanded = Path.expand(path)

        String.starts_with?(expanded, state.directory <> "/") or
          String.starts_with?(expanded, state.legacy_directory <> "/")
      end)

    cond do
      not valid? ->
        {:reply, {:error, :invalid_path}, state}

      map_size(state.retired) >= 10_000 ->
        {:reply, {:error, :capacity}, state}

      true ->
        ref = make_ref()
        Process.send_after(self(), {:retire, ref}, state.config.retention_ms)
        {:reply, :ok, %{state | retired: Map.put(state.retired, ref, paths)}}
    end
  end

  @impl true
  def handle_info({:retire, ref}, state) do
    {paths, retired} = Map.pop(state.retired, ref, [])
    Enum.each(paths, &File.rm/1)
    {:noreply, %{state | retired: retired}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      state.status in [:failed, :ended, :retired] ->
        {:noreply, schedule_cleanup(state)}

      ref == state.owner_ref or Enum.any?(state.tracks, fn {_, track} -> track.ref == ref end) ->
        send(state.owner, {:llhls_failed, state.generation})
        Enum.each(state.tracks, fn {_, %{pid: pid}} -> stop_stream(pid) end)
        :telemetry.execute([:zer0_media, :llhls, :generation_failed], %{count: 1}, %{})
        {:noreply, schedule_cleanup(%{state | status: :failed})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:cleanup, %{status: :ended} = state) do
    # Stop serving the final playlist before deleting its referenced objects.
    Process.send_after(self(), :cleanup, state.config.retention_ms)
    {:noreply, %{state | status: :retired}}
  end

  def handle_info(:cleanup, state) do
    File.rm_rf(state.directory)
    {:stop, :normal, state}
  end

  defp schedule_cleanup(%{cleanup_timer: nil} = state),
    do: %{state | cleanup_timer: Process.send_after(self(), :cleanup, state.config.retention_ms)}

  defp schedule_cleanup(state), do: state

  defp stop_stream(pid) do
    Stream.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
