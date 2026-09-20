defmodule Zer0Media.LLHLS.Playlist do
  @moduledoc """
  Pure, per-rendition publication state. Durations are integer nanoseconds.

  A publisher announces a part only AFTER the complete immutable object is
  readable. Segment completion likewise follows atomic object publication.
  Object names are relative to a unique stream-generation/rendition directory.
  This module neither packages media nor deletes expired objects.
  """

  @second 1_000_000_000
  @max_entries 1024
  defstruct target_duration: 2 * @second,
            part_target: 200_000_000,
            window_segments: 6,
            media_sequence: 0,
            next_msn: 0,
            segments: [],
            parts: [],
            ended?: false

  def new(opts \\ []) do
    state = struct!(__MODULE__, opts)

    unless is_integer(state.target_duration) and state.target_duration in @second..(60 * @second) and
             rem(state.target_duration, @second) == 0 and
             is_integer(state.part_target) and state.part_target > 0 and
             state.part_target <= state.target_duration and
             is_integer(state.window_segments) and state.window_segments in 3..100 and
             state.media_sequence == 0 and state.next_msn == 0 and state.segments == [] and
             state.parts == [] and state.ended? == false do
      raise ArgumentError, "invalid LL-HLS initial state or timing"
    end

    state
  end

  def part_uri(msn, index), do: "part-#{msn}-#{index}.m4s"
  def segment_uri(msn), do: "segment-#{msn}.m4s"
  def next_part_uri(state), do: part_uri(state.next_msn, length(state.parts))

  def publish_part(state, msn, index, duration, independent? \\ false) do
    cond do
      state.ended? ->
        {:error, :ended}

      msn != state.next_msn or index != length(state.parts) ->
        {:error, :out_of_order}

      not is_integer(duration) or duration <= 0 or duration > state.part_target ->
        {:error, :invalid_duration}

      not is_boolean(independent?) ->
        {:error, :invalid_independence}

      short_previous_part?(state, independent?) ->
        {:error, :short_nonfinal_part}

      length(state.parts) >= @max_entries ->
        {:error, :capacity}

      total_duration(state.parts) + duration > state.target_duration ->
        {:error, :segment_too_long}

      true ->
        part = %{
          index: index,
          uri: part_uri(msn, index),
          duration: duration,
          independent?: independent?
        }

        {:ok, %{state | parts: state.parts ++ [part]}}
    end
  end

  # Returned evictions are a storage-retention signal, NOT permission to delete
  # immediately: clients may still be playing a previously served playlist.
  def complete_segment(state, msn, duration) do
    cond do
      state.ended? ->
        {:error, :ended}

      msn != state.next_msn ->
        {:error, :out_of_order}

      not is_integer(duration) or duration <= 0 or duration > state.target_duration ->
        {:error, :invalid_duration}

      state.parts != [] and total_duration(state.parts) != duration ->
        {:error, :duration_mismatch}

      true ->
        segment = %{msn: msn, uri: segment_uri(msn), duration: duration, parts: state.parts}
        {segments, evicted} = trim(state.segments ++ [segment], state, [])

        if length(segments) > @max_entries do
          {:error, :capacity}
        else
          {:ok,
           %{
             state
             | segments: segments,
               parts: [],
               next_msn: msn + 1,
               media_sequence: hd(segments).msn
           }, Enum.reverse(evicted)}
        end
    end
  end

  def finish(%{parts: []} = state), do: {:ok, %{state | ended?: true}}
  def finish(_state), do: {:error, :incomplete_segment}

  @doc "Returns :ready, :wait or a bounded-request error, independently of HTTP."
  def availability(state, msn, part \\ nil)
  def availability(%{ended?: true}, _msn, _part), do: :ready
  def availability(_state, nil, nil), do: :ready
  def availability(_state, nil, _part), do: {:error, :part_without_msn}

  def availability(state, msn, part) do
    cond do
      not valid_integer?(msn) or (part != nil and not valid_integer?(part)) ->
        {:error, :invalid_request}

      msn < state.media_sequence ->
        :ready

      part == nil and msn < state.next_msn ->
        :ready

      part != nil and msn < state.next_msn ->
        completed_part_availability(state, msn, part)

      part != nil and msn == state.next_msn and part < length(state.parts) ->
        :ready

      msn > last_msn(state) + 2 ->
        {:error, :too_far_ahead}

      part != nil and part > last_part_index(state) + advance_part_limit(state) ->
        {:error, :too_far_ahead}

      true ->
        :wait
    end
  end

  @doc "Object requests wait only for the exact hinted part, never roll over to another URI."
  def part_availability(state, msn, index) do
    segment = Enum.find(state.segments, &(&1.msn == msn))

    cond do
      not valid_integer?(msn) or not valid_integer?(index) -> {:error, :invalid_request}
      segment != nil and index < length(segment.parts) -> :ready
      msn == state.next_msn and index < length(state.parts) -> :ready
      msn == state.next_msn and index == length(state.parts) and not state.ended? -> :wait
      true -> {:error, :not_found}
    end
  end

  defp completed_part_availability(state, msn, part) do
    segment = Enum.find(state.segments, &(&1.msn == msn))

    if part < length(segment.parts) do
      :ready
    else
      # Overshooting the final part means part zero of the NEXT segment,
      # including while that next segment has not published its first part.
      availability(state, msn + 1, 0)
    end
  end

  defp short_previous_part?(%{parts: []}, _independent?), do: false

  defp short_previous_part?(state, independent?) do
    last = List.last(state.parts)
    last.duration * 100 < state.part_target * 85 and not last.independent? and not independent?
  end

  defp valid_integer?(n), do: is_integer(n) and n >= 0 and n <= 18_446_744_073_709_551_615
  defp last_msn(%{parts: [], next_msn: msn}), do: msn - 1
  defp last_msn(state), do: state.next_msn
  defp last_part_index(%{parts: [_ | _] = parts}), do: length(parts) - 1
  defp last_part_index(%{segments: []}), do: -1
  defp last_part_index(state), do: length(List.last(state.segments).parts) - 1

  defp advance_part_limit(state) when state.part_target < @second,
    do: div(3 * @second, state.part_target)

  defp advance_part_limit(_state), do: 3

  defp trim([first | rest] = segments, state, evicted) do
    if length(segments) > state.window_segments and
         total_duration(rest) >= 3 * state.target_duration do
      trim(rest, state, [first | evicted])
    else
      {segments, evicted}
    end
  end

  defp total_duration(entries), do: Enum.reduce(entries, 0, &(&1.duration + &2))

  @doc """
  Render a full media playlist. Hints/blocking are opt-in capabilities: callers
  must supply working HTTP handlers before advertising either to a player.
  No viewer identity or credential is included in any media-object URI.
  """
  def render(state, opts \\ []) do
    control = if Keyword.get(opts, :blocking?, false), do: "CAN-BLOCK-RELOAD=YES,", else: ""
    parts? = Keyword.get(opts, :parts?, true)

    [
      "#EXTM3U\n#EXT-X-VERSION:9\n",
      "#EXT-X-TARGETDURATION:#{div(state.target_duration, @second)}\n",
      "#EXT-X-MEDIA-SEQUENCE:#{state.media_sequence}\n",
      if(parts?,
        do:
          "#EXT-X-SERVER-CONTROL:#{control}PART-HOLD-BACK=#{seconds(3 * state.part_target)}\n#EXT-X-PART-INF:PART-TARGET=#{seconds(state.part_target)}\n",
        else: ""
      ),
      "#EXT-X-MAP:URI=\"init.mp4\"\n",
      Enum.map(state.segments, fn segment ->
        [
          if(parts?, do: render_parts(segment.parts), else: ""),
          "#EXTINF:#{seconds(segment.duration)},\n#{segment.uri}\n"
        ]
      end),
      if(parts?, do: render_parts(state.parts), else: ""),
      if(parts? and not state.ended? and Keyword.get(opts, :preload_hint?, false),
        do: "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"#{next_part_uri(state)}\"\n",
        else: ""
      ),
      if(state.ended?, do: "#EXT-X-ENDLIST\n", else: "")
    ]
    |> IO.iodata_to_binary()
  end

  defp render_parts(parts) do
    Enum.map(parts, fn part ->
      independent = if part.independent?, do: ",INDEPENDENT=YES", else: ""
      "#EXT-X-PART:DURATION=#{seconds(part.duration)},URI=\"#{part.uri}\"#{independent}\n"
    end)
  end

  defp seconds(ns),
    do:
      "#{div(ns, @second)}." <>
        (rem(ns, @second) |> Integer.to_string() |> String.pad_leading(9, "0"))
end
