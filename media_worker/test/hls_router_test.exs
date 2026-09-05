defmodule Zer0Media.HLSRouterTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Zer0Media.HLSRouter

  Code.require_file("../../zer0_stream/lib/zer0_stream/playback_token.ex", __DIR__)

  defp playback_token(session_id, viewer_id \\ "viewer-a", ttl \\ 3600),
    do: Zer0Stream.PlaybackToken.issue_for_viewer(session_id, viewer_id, ttl)

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
    previous_control_plane_auth_secret = System.get_env("CONTROL_PLANE_AUTH_SECRET")
    Application.put_env(:zer0_media, :hls_dir, hls_dir)
    Application.put_env(:zer0_media, :hls_allowed_origins, ["https://zer0.tv"])
    System.put_env("CONTROL_PLANE_AUTH_SECRET", "test-control-plane-auth-secret")

    on_exit(fn ->
      restore_config(:hls_dir, previous_hls_dir)
      restore_config(:hls_allowed_origins, previous_allowed_origins)
      restore_env("CONTROL_PLANE_AUTH_SECRET", previous_control_plane_auth_secret)
      File.rm_rf!(hls_dir)
    end)

    {:ok, hls_dir: hls_dir}
  end

  test "allows configured browser origins" do
    conn =
      :get
      |> conn("/hls/playlist.m3u8?token=#{playback_token(nil)}")
      |> put_req_header("origin", "https://zer0.tv")
      |> HLSRouter.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://zer0.tv"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "does not allow unconfigured browser origins" do
    conn =
      :get
      |> conn("/hls/playlist.m3u8?token=#{playback_token(nil)}")
      |> put_req_header("origin", "https://untrusted.example")
      |> HLSRouter.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "registers an HLS viewer once per viewer identifier", %{hls_dir: hls_dir} do
    session_id = Integer.to_string(System.unique_integer([:positive]))
    session_dir = Path.join(hls_dir, "stream-session-#{session_id}")
    File.mkdir_p!(session_dir)
    File.write!(Path.join(session_dir, "master.m3u8"), "#EXTM3U\n")

    HLSRouter.call(
      conn(
        :get,
        "/hls/stream-session-#{session_id}/master.m3u8?token=#{playback_token(session_id)}"
      ),
      []
    )

    HLSRouter.call(
      conn(
        :get,
        "/hls/stream-session-#{session_id}/master.m3u8?token=#{playback_token(session_id)}"
      ),
      []
    )

    assert Zer0Media.ViewerTracker.count(session_id).viewer_count == 1
  end

  test "propagates a stable viewer identifier through HLS playlist references", %{
    hls_dir: hls_dir
  } do
    session_id = Integer.to_string(System.unique_integer([:positive]))
    session_dir = Path.join(hls_dir, "stream-session-#{session_id}")
    File.mkdir_p!(session_dir)

    File.write!(
      Path.join(session_dir, "master.m3u8"),
      "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\nsegment.m4s\n"
    )

    conn =
      HLSRouter.call(
        conn(
          :get,
          "/hls/stream-session-#{session_id}/master.m3u8?token=#{playback_token(session_id)}"
        ),
        []
      )

    File.write!(Path.join(session_dir, "init.mp4"), "init")
    File.write!(Path.join(session_dir, "segment.m4s"), "media")
    [_, init_uri] = Regex.run(~r/URI="([^"]+)"/, conn.resp_body)

    segment_uri =
      conn.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "segment.m4s?"))

    for uri <- [init_uri, segment_uri] do
      assert URI.decode_query(URI.parse(uri).query)["viewer_id"] == "viewer:viewer-a"

      assert HLSRouter.call(conn(:get, "/hls/stream-session-#{session_id}/#{uri}"), []).status ==
               200
    end

    assert Zer0Media.ViewerTracker.count(session_id).viewer_count == 1
  end

  test "deduplicates tabs, refreshed tokens, and transport identities", %{hls_dir: hls_dir} do
    id = Integer.to_string(System.unique_integer([:positive]))
    dir = Path.join(hls_dir, "stream-session-#{id}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "master.m3u8"), "#EXTM3U\n")

    for ttl <- [100, 200] do
      token = playback_token(id, "alice", ttl)

      conn =
        HLSRouter.call(
          conn(:get, "/hls/stream-session-#{id}/master.m3u8?token=#{token}&viewer_id=forged"),
          []
        )

      assert conn.status == 200
      # WebRTC uses this same verified token identity for pipeline heartbeats.
      assert {:ok, viewer_id} = Zer0Media.PlaybackToken.viewer_id(token, id)
      Zer0Media.ViewerTracker.heartbeat(id, viewer_id)
    end

    assert Zer0Media.ViewerTracker.count(id).viewer_count == 1
    token = playback_token(id, "bob")

    assert HLSRouter.call(conn(:get, "/hls/stream-session-#{id}/master.m3u8?token=#{token}"), []).status ==
             200

    assert Zer0Media.ViewerTracker.count(id).viewer_count == 2
    expired = playback_token(id, "expired", -1)

    assert HLSRouter.call(
             conn(:get, "/hls/stream-session-#{id}/master.m3u8?token=#{expired}"),
             []
           ).status == 401

    assert Zer0Media.ViewerTracker.count(id).viewer_count == 2
  end

  test "media verifier accepts legacy tokens and rejects modified identity or stream" do
    legacy = Zer0Stream.PlaybackToken.issue(42)

    assert Zer0Media.PlaybackToken.viewer_id(legacy, "42") ==
             Zer0Stream.PlaybackToken.viewer_id(legacy, "42")

    token = playback_token(42, "alice")
    assert Zer0Media.PlaybackToken.viewer_id(token, "43") == :error

    tampered =
      token
      |> Base.url_decode64!(padding: false)
      |> String.replace("alice", "bob")
      |> Base.url_encode64(padding: false)

    assert Zer0Media.PlaybackToken.viewer_id(tampered, "42") == :error
  end

  test "WebRTC rejects unsigned or expired tokens before upgrading" do
    id = Integer.to_string(System.unique_integer([:positive]))
    :ok = Zer0Media.WebRTCSignalingRegistry.register(id, self())
    assert HLSRouter.call(conn(:get, "/webrtc/#{id}"), []).status == 401
    token = playback_token(id, "alice", -1)
    assert HLSRouter.call(conn(:get, "/webrtc/#{id}?token=#{token}"), []).status == 401
  end

  test "returns a control-plane authenticated viewer-count snapshot" do
    session_id = Integer.to_string(System.unique_integer([:positive]))
    Zer0Media.ViewerTracker.heartbeat(session_id, "viewer-a")
    path = "/api/sessions/#{session_id}/viewers"
    {timestamp, signature} = Zer0Media.ControlPlaneAuth.sign(:get, path, %{})

    conn =
      :get
      |> conn(path)
      |> put_req_header("x-zer0-timestamp", timestamp)
      |> put_req_header("x-zer0-signature", signature)
      |> HLSRouter.call([])

    assert conn.status == 200

    assert %{"session_id" => response_session_id, "viewer_count" => 1, "updated_at" => updated_at} =
             Jason.decode!(conn.resp_body)

    assert response_session_id == String.to_integer(session_id)
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(updated_at)
  end

  test "rejects unsigned viewer-count requests" do
    conn = HLSRouter.call(conn(:get, "/api/sessions/42/viewers"), [])

    assert conn.status == 401
    assert conn.resp_body == ~s({"error":"unauthorized"})
  end

  defp restore_config(key, nil), do: Application.delete_env(:zer0_media, key)
  defp restore_config(key, value), do: Application.put_env(:zer0_media, key, value)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
