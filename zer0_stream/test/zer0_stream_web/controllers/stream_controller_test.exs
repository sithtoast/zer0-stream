defmodule Zer0StreamWeb.StreamControllerTest do
  use Zer0StreamWeb.ConnCase

  alias Zer0Stream.Streams

  test "reports ready when the database is available", %{conn: conn} do
    conn = get(conn, "/api/ready")

    assert %{"ok" => true, "service" => "zer0-stream", "status" => "ready"} =
             json_response(conn, 200)
  end

  test "creates a creator", %{conn: conn} do
    params = %{external_id: "creator-1", display_name: "Creator One"}

    conn =
      conn
      |> service_conn(:post, "/api/control/creators", params)
      |> post("/api/control/creators", params)

    assert %{"creator" => creator} = json_response(conn, 200)
    assert creator["external_id"] == "creator-1"
    assert creator["display_name"] == "Creator One"
  end

  test "rejects a creator without an external id", %{conn: conn} do
    params = %{display_name: "Missing ID"}

    conn =
      conn
      |> service_conn(:post, "/api/control/creators", params)
      |> post("/api/control/creators", params)

    assert %{"errors" => %{"external_id" => ["can't be blank"]}} = json_response(conn, 422)
  end

  test "creates a persistent stream for a creator", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-2"})

    params = %{creator_id: creator.id, title: "Live Test", request_id: "create-stream-1"}

    conn =
      conn
      |> service_conn(:post, "/api/control/streams", params)
      |> post("/api/control/streams", params)

    assert %{"stream" => stream} = json_response(conn, 201)
    assert stream["creator_id"] == creator.id
    assert stream["title"] == "Live Test"
    assert stream["status"] == "offline"
  end

  test "returns the original stream for an idempotent create retry", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-idempotent"})
    params = %{creator_id: creator.id, title: "Live Test", request_id: "create-stream-retry"}

    first_conn =
      conn
      |> service_conn(:post, "/api/control/streams", params)
      |> post("/api/control/streams", params)

    assert %{"stream" => %{"id" => stream_id}} = json_response(first_conn, 201)

    second_conn =
      build_conn()
      |> service_conn(:post, "/api/control/streams", params)
      |> post("/api/control/streams", params)

    assert %{"stream" => %{"id" => ^stream_id}} = json_response(second_conn, 200)
  end

  test "rotates creator keys and revokes the previous key", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-3"})
    {:ok, _stream} = Streams.create_stream(%{creator_id: creator.id, title: "Key Test"})
    params = %{request_id: "rotate-key-1"}

    first_conn =
      conn
      |> service_conn(:post, "/api/control/creators/#{creator.id}/keys", params)
      |> post("/api/control/creators/#{creator.id}/keys", params)

    assert %{"stream_key" => %{"token" => first_token}} = json_response(first_conn, 200)

    second_conn =
      build_conn()
      |> service_conn(:post, "/api/control/creators/#{creator.id}/keys", params)
      |> post("/api/control/creators/#{creator.id}/keys", params)

    assert %{"stream_key" => %{"token" => second_token}} = json_response(second_conn, 200)
    assert first_token != second_token

    creator_id = creator.id
    assert Streams.authenticate_stream_key(first_token) == nil
    assert %{creator: %{id: ^creator_id}} = Streams.authenticate_stream_key(second_token)
  end

  test "returns not found when rotating a missing creator key", %{conn: conn} do
    params = %{request_id: "rotate-key-missing"}

    conn =
      conn
      |> service_conn(:post, "/api/control/creators/999999/keys", params)
      |> post("/api/control/creators/999999/keys", params)

    assert response(conn, 404) == ""
  end

  test "rejects an unsigned control request", %{conn: conn} do
    conn = post(conn, "/api/control/creators", %{external_id: "creator-unsigned"})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "returns the playback URL for a live stream session", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-playback"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Playback Test"})
    {:ok, %{token: token}} = Streams.rotate_creator_stream_key(creator)
    {:ok, session} = Zer0Stream.Ingest.authorize_rtmp(token, "playback-connection")

    conn =
      conn
      |> service_conn(:get, "/api/streams/#{stream.id}/playback", %{})
      |> get("/api/streams/#{stream.id}/playback")

    assert %{"playback_url" => url, "session_id" => session_id} = json_response(conn, 200)
    assert session_id == session.id
    assert url =~ "/hls-boombox/stream-session-#{session.id}/master.m3u8?token="
  end

  test "signed playback request carries viewer identity", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "stable-viewer"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Stable"})
    {:ok, %{token: key}} = Streams.rotate_creator_stream_key(creator)
    {:ok, session} = Zer0Stream.Ingest.authorize_rtmp(key, "stable-viewer-connection")
    path = "/api/streams/#{stream.id}/playback"
    params = %{"viewer_id" => "opaque-alice"}
    result = conn |> service_conn(:post, path, params) |> post(path, params) |> json_response(200)

    token =
      result["playback_url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("token")

    assert Zer0Stream.PlaybackToken.viewer_id(token, session.id) == {:ok, "viewer:opaque-alice"}
  end

  test "does not return playback for an offline stream", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-offline"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Offline Test"})

    conn =
      conn
      |> service_conn(:get, "/api/streams/#{stream.id}/playback", %{})
      |> get("/api/streams/#{stream.id}/playback")

    assert response(conn, 404) == ""
  end

  test "returns zero viewers for an offline stream", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-viewers-offline"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Viewer Test"})
    path = "/api/streams/#{stream.id}/viewers"

    conn =
      conn
      |> service_conn(:get, path, %{})
      |> get(path)

    assert %{"stream_id" => stream_id, "viewer_count" => 0, "live" => false} =
             json_response(conn, 200)

    assert stream_id == stream.id
  end

  test "returns title/category update history for a stream", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-updates"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Update Test"})
    {:ok, %{token: token}} = Streams.rotate_creator_stream_key(creator)
    {:ok, _session} = Zer0Stream.Ingest.authorize_rtmp(token, "updates-connection")

    {:ok, _updated} =
      Streams.update_stream_with_history(stream, %{
        "title" => "New Title",
        "category_name" => "RPG",
        "category_twitch_id" => "123"
      })

    path = "/api/streams/#{stream.id}/updates"

    conn =
      conn
      |> service_conn(:get, path, %{})
      |> get(path)

    assert %{"stream_id" => stream_id, "updates" => [update]} = json_response(conn, 200)
    assert stream_id == stream.id
    assert update["title"] == "New Title"
    assert update["category_name"] == "RPG"
    assert update["category_twitch_id"] == "123"
    assert update["session_id"] != nil
  end

  test "returns not found for updates on a missing stream", %{conn: conn} do
    conn =
      conn
      |> service_conn(:get, "/api/streams/999999/updates", %{})
      |> get("/api/streams/999999/updates")

    assert response(conn, 404) == ""
  end

  test "rejects playback token issuance without main-app authentication", %{conn: conn} do
    conn = get(conn, "/api/streams/1/playback")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "rejects worker authentication on a main-app route", %{conn: conn} do
    params = %{external_id: "wrong-scope"}

    conn =
      conn
      |> service_conn(:worker, :post, "/api/control/creators", params)
      |> post("/api/control/creators", params)

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
