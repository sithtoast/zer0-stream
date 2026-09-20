defmodule Zer0Media.LLHLS.Storage do
  @moduledoc """
  Adapts the installed Membrane storage callbacks to immutable LL-HLS objects.
  Standard HLS playlists remain available in the original directory, without
  unsupported low-latency directives. Actual fragment bytes come from Membrane.
  """
  @behaviour Membrane.HTTPAdaptiveStream.Storage
  alias Zer0Media.LLHLS.{LocalStore, Origin, Playlist, Stream}
  @enforce_keys [:directory, :origin]
  defstruct [:directory, :origin, tracks: %{}]

  @impl true
  def init(config), do: config

  @impl true
  def store(track, name, bytes, metadata, context, state) do
    started = System.monotonic_time()
    result = do_store(track, name, bytes, metadata, context, state)

    :telemetry.execute(
      [:zer0_media, :llhls, :storage],
      %{duration: System.monotonic_time() - started, bytes: byte_size(bytes)},
      %{type: context.type, success?: elem(result, 0) == :ok}
    )

    result
  end

  defp do_store(track, name, bytes, _, %{type: :header}, state) do
    with false <- Map.has_key?(state.tracks, track),
         {:ok, stream, directory} <- Origin.track(state.origin, track),
         :ok <- LocalStore.put(Path.join(directory, "init.mp4"), bytes),
         :ok <- LocalStore.put(Path.join(state.directory, name), bytes) do
      track_state = %{
        stream: stream,
        directory: directory,
        msn: 0,
        part: 0,
        duration: 0,
        bytes: 0
      }

      {:ok, %{state | tracks: Map.put(state.tracks, track, track_state)}}
    else
      true -> {{:error, :codec_change_requires_new_generation}, state}
      error -> {error, state}
    end
  end

  defp do_store(track, _name, bytes, metadata, %{type: :partial_segment}, state) do
    current = Map.fetch!(state.tracks, track)
    duration = ns(metadata.duration)

    with true <-
           metadata.sequence_number == current.part and metadata.byte_offset == current.bytes,
         :ok <-
           LocalStore.put(
             Path.join(current.directory, Playlist.part_uri(current.msn, current.part)),
             bytes
           ),
         :ok <-
           Stream.publish_part(
             current.stream,
             current.msn,
             current.part,
             duration,
             metadata.independent?
           ),
         :ok <- mark_ready(state.origin, track, current.part) do
      current = %{
        current
        | part: current.part + 1,
          duration: current.duration + duration,
          bytes: current.bytes + byte_size(bytes)
      }

      {:ok, put_in(state.tracks[track], current)}
    else
      false -> {{:error, :out_of_order}, state}
      error -> {error, state}
    end
  end

  defp do_store(track, name, bytes, metadata, %{type: :segment}, state) do
    current = Map.fetch!(state.tracks, track)

    with true <-
           metadata.sequence_number == current.msn and byte_size(bytes) == current.bytes and
             abs(ns(metadata.duration) - current.duration) <= current.part,
         :ok <-
           LocalStore.put(Path.join(current.directory, Playlist.segment_uri(current.msn)), bytes),
         :ok <- LocalStore.put(Path.join(state.directory, name), bytes),
         {:ok, evicted} <- Stream.complete_segment(current.stream, current.msn, current.duration),
         :ok <- retire_segments(state.origin, current.directory, evicted) do
      current = %{current | msn: current.msn + 1, part: 0, duration: 0, bytes: 0}
      {:ok, put_in(state.tracks[track], current)}
    else
      false -> {{:error, :invalid_segment}, state}
      error -> {error, state}
    end
  end

  defp do_store(:master, name, body, _, %{type: :manifest}, state) do
    with :ok <- LocalStore.put(Path.join(state.directory, name), body, :replace),
         :ok <- Origin.master(state.origin, body),
         do: {:ok, state},
         else: (error -> {error, state})
  end

  defp do_store(track, name, body, _, %{type: :manifest}, state) do
    if Map.has_key?(state.tracks, track) do
      with :ok <-
             LocalStore.put(Path.join(state.directory, name), standard_playlist(body), :replace),
           :ok <- maybe_finish(state, track, body),
           do: {:ok, state},
           else: (error -> {error, state})
    else
      # Upstream emits delta variants too; this origin doesn't advertise or
      # serve delta updates until their merge semantics are implemented.
      {:ok, state}
    end
  end

  @impl true
  def remove(_track, name, _context, state) do
    {Origin.retire(state.origin, [Path.join(state.directory, name)]), state}
  end

  defp standard_playlist(body) do
    body
    |> String.split("\n")
    |> Enum.reject(
      &String.starts_with?(&1, [
        "#EXT-X-PART",
        "#EXT-X-PRELOAD-HINT",
        "#EXT-X-SERVER-CONTROL",
        "#EXT-X-SKIP",
        "#EXT-X-RENDITION-REPORT"
      ])
    )
    |> Enum.join("\n")
  end

  defp maybe_finish(state, track, body) do
    if String.contains?(body, "#EXT-X-ENDLIST") do
      with :ok <- Stream.finish(state.tracks[track].stream),
           do: Origin.finish_track(state.origin, track)
    else
      :ok
    end
  end

  defp retire_segments(_origin, _directory, []), do: :ok

  defp retire_segments(origin, directory, segments) do
    files =
      for segment <- segments,
          file <- [segment.uri | Enum.map(segment.parts, & &1.uri)],
          do: Path.join(directory, file)

    Origin.retire(origin, files)
  end

  defp mark_ready(origin, track, 0), do: Origin.published(origin, track)
  defp mark_ready(_origin, _track, _part), do: :ok

  defp ns(n) when is_integer(n), do: n
  defp ns(%Ratio{} = n), do: n |> Ratio.to_float() |> round()
end
