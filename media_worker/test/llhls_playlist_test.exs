defmodule Zer0Media.LLHLS.PlaylistTest do
  use ExUnit.Case, async: true
  alias Zer0Media.LLHLS.Playlist
  @part 200_000_000
  @second 1_000_000_000

  test "first part, multiple parts, completion and the next parent sequence" do
    state = Playlist.new()
    assert :wait = Playlist.availability(state, 0, 0)
    assert {:ok, state} = Playlist.publish_part(state, 0, 0, @part, true)
    assert :ready = Playlist.availability(state, 0, 0)
    assert :wait = Playlist.availability(state, 0)
    assert Playlist.next_part_uri(state) == "part-0-1.m4s"
    assert {:ok, state} = Playlist.publish_part(state, 0, 1, @part)
    assert {:ok, state, []} = Playlist.complete_segment(state, 0, 2 * @part)
    assert :ready = Playlist.availability(state, 0)
    assert :ready = Playlist.availability(state, 0, 1)
    assert :wait = Playlist.availability(state, 0, 2)
    assert :wait = Playlist.availability(state, 1, 0)
    assert Playlist.next_part_uri(state) == "part-1-0.m4s"
    assert {:ok, state} = Playlist.publish_part(state, 1, 0, @part, true)
    assert :ready = Playlist.availability(state, 0, 999)
    assert :ready = Playlist.availability(state, 1, 0)
  end

  test "completion rejects duplicates, wrong sequences, and mismatched durations" do
    state = Playlist.new()
    assert {:error, :out_of_order} = Playlist.publish_part(state, 1, 0, @part)
    assert {:error, :out_of_order} = Playlist.publish_part(state, 0, 1, @part)
    assert {:ok, state} = Playlist.publish_part(state, 0, 0, @part)
    assert {:error, :out_of_order} = Playlist.publish_part(state, 0, 0, @part)
    assert {:error, :duration_mismatch} = Playlist.complete_segment(state, 0, @second)
    assert {:error, :incomplete_segment} = Playlist.finish(state)
    assert {:ok, state, []} = Playlist.complete_segment(state, 0, @part)
    assert {:error, :out_of_order} = Playlist.complete_segment(state, 0, @part)
  end

  test "window expiration advances media sequence, but expired requests receive the latest playlist" do
    state = Playlist.new(window_segments: 3)

    {state, evictions} =
      Enum.reduce(0..7, {state, []}, fn msn, {state, evictions} ->
        {:ok, state, evicted} = Playlist.complete_segment(state, msn, 2 * @second)
        {state, evictions ++ evicted}
      end)

    assert state.media_sequence == 5
    assert Enum.map(state.segments, & &1.msn) == [5, 6, 7]
    assert Enum.map(evictions, & &1.msn) == [0, 1, 2, 3, 4]
    assert :ready = Playlist.availability(state, 0, 400)
    assert :ready = Playlist.availability(state, 0)
    assert Playlist.render(state) =~ "#EXT-X-MEDIA-SEQUENCE:5\n"
  end

  test "short segments cannot trim the live window below three target durations" do
    state =
      Enum.reduce(0..8, Playlist.new(window_segments: 3), fn msn, state ->
        {:ok, state, _} = Playlist.complete_segment(state, msn, @second)
        state
      end)

    assert length(state.segments) == 6
    assert state.media_sequence == 3
  end

  test "a final short part is represented without rounding away timestamp precision" do
    {:ok, state} = Playlist.publish_part(Playlist.new(), 0, 0, @part, true)
    {:ok, state} = Playlist.publish_part(state, 0, 1, 10_666_667)
    {:ok, state, []} = Playlist.complete_segment(state, 0, @part + 10_666_667)
    assert Playlist.render(state) =~ "DURATION=0.010666667"
    assert Playlist.render(state) =~ "#EXTINF:0.210666667,"
  end

  test "short nonfinal parts require an independent boundary" do
    {:ok, state} = Playlist.publish_part(Playlist.new(), 0, 0, 1)
    assert {:error, :short_nonfinal_part} = Playlist.publish_part(state, 0, 1, @part)
    assert {:ok, _} = Playlist.publish_part(state, 0, 1, @part, true)
    {:ok, state} = Playlist.publish_part(Playlist.new(), 0, 0, 1, true)
    assert {:ok, _} = Playlist.publish_part(state, 0, 1, @part)
  end

  test "pathological publication hits a hard metadata capacity" do
    state =
      Enum.reduce(0..1023, Playlist.new(), fn index, state ->
        {:ok, state} = Playlist.publish_part(state, 0, index, 1, true)
        state
      end)

    assert {:error, :capacity} = Playlist.publish_part(state, 0, 1024, 1, true)

    state =
      Enum.reduce(0..1023, Playlist.new(), fn msn, state ->
        {:ok, state, []} = Playlist.complete_segment(state, msn, 1)
        state
      end)

    assert {:error, :capacity} = Playlist.complete_segment(state, 1024, 1)
  end

  test "future requests and malformed requests are bounded" do
    state = Playlist.new()
    assert {:error, :part_without_msn} = Playlist.availability(state, nil, 0)
    assert {:error, :invalid_request} = Playlist.availability(state, -1)
    assert {:error, :invalid_request} = Playlist.availability(state, "0", 0)
    assert {:error, :invalid_request} = Playlist.availability(state, 0, -1)
    assert {:error, :invalid_request} = Playlist.availability(state, 18_446_744_073_709_551_616)
    assert :wait = Playlist.availability(state, 1)
    assert {:error, :too_far_ahead} = Playlist.availability(state, 2)
    {:ok, state} = Playlist.publish_part(state, 0, 0, @part)
    assert :wait = Playlist.availability(state, 2)
    assert {:error, :too_far_ahead} = Playlist.availability(state, 3)
    assert :wait = Playlist.availability(state, 0, 15)
    assert {:error, :too_far_ahead} = Playlist.availability(state, 0, 16)
    slow = Playlist.new(part_target: @second)
    {:ok, slow} = Playlist.publish_part(slow, 0, 0, @second)
    assert :wait = Playlist.availability(slow, 0, 3)
    assert {:error, :too_far_ahead} = Playlist.availability(slow, 0, 4)
  end

  test "ended streams ignore delivery directives and cannot accept more media" do
    {:ok, state, []} = Playlist.complete_segment(Playlist.new(), 0, @second)
    {:ok, state} = Playlist.finish(state)
    assert :ready = Playlist.availability(state, 999_999, 999_999)
    assert {:error, :ended} = Playlist.publish_part(state, 1, 0, @part)
    assert {:error, :ended} = Playlist.complete_segment(state, 1, @second)
    body = Playlist.render(state, blocking?: true, preload_hint?: true)
    assert String.ends_with?(body, "#EXT-X-ENDLIST\n")
    refute body =~ "PRELOAD-HINT"
  end

  test "playlist tags, safe shared object names, optional capabilities and standard fallback" do
    {:ok, state} = Playlist.publish_part(Playlist.new(), 0, 0, @part, true)
    body = Playlist.render(state, blocking?: true, preload_hint?: true)
    assert String.starts_with?(body, "#EXTM3U\n#EXT-X-VERSION:9\n")
    assert body =~ "#EXT-X-TARGETDURATION:2\n"
    assert body =~ "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=0.600000000\n"
    assert body =~ "#EXT-X-PART-INF:PART-TARGET=0.200000000\n"
    assert body =~ "#EXT-X-PART:DURATION=0.200000000,URI=\"part-0-0.m4s\",INDEPENDENT=YES\n"
    assert body =~ "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"part-0-1.m4s\"\n"
    refute body =~ "token"
    refute body =~ "viewer_id"
    refute Playlist.render(state) =~ "PRELOAD-HINT"
    refute Playlist.render(state) =~ "CAN-BLOCK-RELOAD"
    {:ok, state, []} = Playlist.complete_segment(state, 0, @part)
    fallback = Playlist.render(state, parts?: false)
    assert fallback =~ "#EXTINF:0.200000000,\nsegment-0.m4s\n"
    refute fallback =~ "#EXT-X-PART"
    refute fallback =~ "#EXT-X-SERVER-CONTROL"
  end

  test "an independent HLS parser accepts LL-HLS and fallback output" do
    {:ok, state} = Playlist.publish_part(Playlist.new(), 0, 0, @part, true)
    {:ok, state, []} = Playlist.complete_segment(state, 0, @part)
    {:ok, state} = Playlist.publish_part(state, 1, 0, @part, true)
    body = Playlist.render(state, blocking?: true, preload_hint?: true)
    assert {:ok, parsed} = ExM3U8.deserialize_media_playlist(body)
    assert parsed.info.target_duration == 2
    assert parsed.info.media_sequence == 0
    assert parsed.info.part_inf == 0.2
    assert Enum.count(parsed.timeline, &match?(%ExM3U8.Tags.Part{}, &1)) == 2
    assert Enum.count(parsed.timeline, &match?(%ExM3U8.Tags.PreloadHint{}, &1)) == 1
    assert {:ok, _} = ExM3U8.deserialize_media_playlist(Playlist.render(state, parts?: false))
  end

  test "invalid state and publication cannot grow unbounded metadata" do
    for opts <- [[part_target: 0], [target_duration: 1], [window_segments: 2], [next_msn: 1]] do
      assert_raise ArgumentError, fn -> Playlist.new(opts) end
    end

    state = Playlist.new()

    for duration <- [0, -1, @part + 1, 0.2] do
      assert {:error, :invalid_duration} = Playlist.publish_part(state, 0, 0, duration)
    end

    assert {:error, :invalid_independence} = Playlist.publish_part(state, 0, 0, @part, :yes)
    assert {:error, :invalid_duration} = Playlist.complete_segment(state, 0, 3 * @second)

    state =
      Enum.reduce(0..9, state, fn n, state ->
        {:ok, state} = Playlist.publish_part(state, 0, n, @part)
        state
      end)

    assert {:error, :segment_too_long} = Playlist.publish_part(state, 0, 10, @part)
  end
end
