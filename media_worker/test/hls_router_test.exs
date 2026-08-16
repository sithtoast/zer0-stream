defmodule Zer0Media.HLSRouterTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Zer0Media.HLSRouter

  test "reports media worker health" do
    conn = HLSRouter.call(conn(:get, "/health"), [])

    assert conn.status == 200
    assert conn.resp_body == ~s({"ok":true,"service":"zer0-media","status":"healthy"})
  end

  setup do
    hls_dir = Path.join(System.tmp_dir!(), "zer0-media-hls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(hls_dir)
    File.write!(Path.join(hls_dir, "playlist.m3u8"), "#EXTM3U\n")

    previous_hls_dir = Application.get_env(:zer0_media, :hls_dir)
    previous_allowed_origins = Application.get_env(:zer0_media, :hls_allowed_origins)
    Application.put_env(:zer0_media, :hls_dir, hls_dir)
    Application.put_env(:zer0_media, :hls_allowed_origins, ["https://zer0.tv"])

    on_exit(fn ->
      restore_config(:hls_dir, previous_hls_dir)
      restore_config(:hls_allowed_origins, previous_allowed_origins)
      File.rm_rf!(hls_dir)
    end)

    :ok
  end

  test "allows configured browser origins" do
    conn =
      :get
      |> conn("/hls/playlist.m3u8")
      |> put_req_header("origin", "https://zer0.tv")
      |> HLSRouter.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://zer0.tv"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "does not allow unconfigured browser origins" do
    conn =
      :get
      |> conn("/hls/playlist.m3u8")
      |> put_req_header("origin", "https://untrusted.example")
      |> HLSRouter.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  defp restore_config(key, nil), do: Application.delete_env(:zer0_media, key)
  defp restore_config(key, value), do: Application.put_env(:zer0_media, key, value)
end
