defmodule Zer0Media.ViewerTrackerTest do
  use ExUnit.Case, async: false

  alias Zer0Media.ViewerTracker

  setup do
    previous_ttl = Application.get_env(:zer0_media, :viewer_ttl_seconds)
    previous_snapshot_interval = Application.get_env(:zer0_media, :viewer_snapshot_interval_ms)
    previous_average_window = Application.get_env(:zer0_media, :viewer_average_window_seconds)

    Application.put_env(:zer0_media, :viewer_ttl_seconds, 1)
    Application.put_env(:zer0_media, :viewer_snapshot_interval_ms, 10)
    Application.put_env(:zer0_media, :viewer_average_window_seconds, 30)
    Zer0Media.ViewerTracker.reset()

    on_exit(fn ->
      if previous_ttl do
        Application.put_env(:zer0_media, :viewer_ttl_seconds, previous_ttl)
      else
        Application.delete_env(:zer0_media, :viewer_ttl_seconds)
      end

      if previous_snapshot_interval do
        Application.put_env(:zer0_media, :viewer_snapshot_interval_ms, previous_snapshot_interval)
      else
        Application.delete_env(:zer0_media, :viewer_snapshot_interval_ms)
      end

      if previous_average_window do
        Application.put_env(:zer0_media, :viewer_average_window_seconds, previous_average_window)
      else
        Application.delete_env(:zer0_media, :viewer_average_window_seconds)
      end

      Zer0Media.ViewerTracker.reset()
    end)

    :ok
  end

  test "registers viewers without double-counting repeated heartbeats" do
    assert ViewerTracker.heartbeat(42, "viewer-a") == :ok
    assert ViewerTracker.heartbeat(42, "viewer-a") == :ok
    assert ViewerTracker.count(42).viewer_count == 1
  end

  test "removes expired viewers" do
    ViewerTracker.heartbeat(42, "viewer-a")
    Process.sleep(1_050)

    assert ViewerTracker.count(42).viewer_count == 0
  end

  test "keeps streams independent and reports zero viewers" do
    ViewerTracker.heartbeat(42, "viewer-a")
    ViewerTracker.heartbeat(43, "viewer-a")

    assert ViewerTracker.count(42).viewer_count == 1
    assert ViewerTracker.count(43).viewer_count == 1
    assert ViewerTracker.count(44).viewer_count == 0
  end

  test "serializes concurrent heartbeats for the same viewer" do
    1..50
    |> Task.async_stream(fn _ -> ViewerTracker.heartbeat(42, "viewer-a") end,
      max_concurrency: 50,
      timeout: 5_000
    )
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    assert ViewerTracker.count(42).viewer_count == 1
  end

  test "tracks a rolling average for recent viewer counts" do
    ViewerTracker.heartbeat(42, "viewer-a")
    ViewerTracker.heartbeat(42, "viewer-b")
    Process.sleep(40)
    ViewerTracker.heartbeat(42, "viewer-b")
    ViewerTracker.heartbeat(42, "viewer-c")

    snapshot = ViewerTracker.count(42)

    assert snapshot.viewer_count == 3
    assert snapshot.average_viewer_count_15m >= 1.0
  end

  test "removes an ended stream from future samples" do
    ViewerTracker.heartbeat(42, "viewer-a")
    ViewerTracker.heartbeat(43, "viewer-b")

    assert {"42", 1} in ViewerTracker.samples()
    assert {"43", 1} in ViewerTracker.samples()

    assert ViewerTracker.stop(42) == :ok
    refute Enum.any?(ViewerTracker.samples(), fn {stream_id, _count} -> stream_id == "42" end)
    assert {"43", 1} in ViewerTracker.samples()
  end
end