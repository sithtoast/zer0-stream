defmodule Zer0Media.HLSCleanupTest do
  use ExUnit.Case, async: false

  alias Zer0Media.HLSCleanup

  setup do
    root = Path.join(System.tmp_dir!(), "zer0-media-cleanup-#{System.unique_integer([:positive])}")
    previous_hls_dir = Application.get_env(:zer0_media, :hls_dir)
    previous_boombox_hls_dir = Application.get_env(:zer0_media, :boombox_hls_dir)
    previous_grace = Application.get_env(:zer0_media, :hls_cleanup_grace_ms)

    Application.put_env(:zer0_media, :hls_dir, root)
    Application.put_env(:zer0_media, :boombox_hls_dir, Path.join(root, "boombox"))

    on_exit(fn ->
      restore_config(:hls_dir, previous_hls_dir)
      restore_config(:boombox_hls_dir, previous_boombox_hls_dir)
      restore_config(:hls_cleanup_grace_ms, previous_grace)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "removes stale session directories when it starts", %{root: root} do
    stale_directory = Path.join(root, "stream-session-stale")
    File.mkdir_p!(stale_directory)

    {:ok, cleanup} = HLSCleanup.start_link(name: nil)
    assert not File.exists?(stale_directory)
    GenServer.stop(cleanup)
  end

  test "removes completed session artifacts after the configured grace period", %{root: root} do
    directory = Path.join(root, "stream-session-completed")
    File.mkdir_p!(directory)
    Application.put_env(:zer0_media, :hls_cleanup_grace_ms, 0)

    HLSCleanup.schedule(directory)

    assert_eventually(fn -> not File.exists?(directory) end)
  end

  defp assert_eventually(check, attempts \\ 20)

  defp assert_eventually(check, attempts) when attempts > 0 do
    if check.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(check, attempts - 1)
    end
  end

  defp assert_eventually(check, 0), do: assert(check.())

  defp restore_config(key, nil), do: Application.delete_env(:zer0_media, key)
  defp restore_config(key, value), do: Application.put_env(:zer0_media, key, value)
end