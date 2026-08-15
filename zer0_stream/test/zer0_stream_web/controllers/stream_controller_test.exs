defmodule Zer0StreamWeb.StreamControllerTest do
  use Zer0StreamWeb.ConnCase

  alias Zer0Stream.Streams

  test "creates a creator", %{conn: conn} do
    conn =
      post(conn, "/api/control/creators", %{external_id: "creator-1", display_name: "Creator One"})

    assert %{"creator" => creator} = json_response(conn, 200)
    assert creator["external_id"] == "creator-1"
    assert creator["display_name"] == "Creator One"
  end

  test "rejects a creator without an external id", %{conn: conn} do
    conn = post(conn, "/api/control/creators", %{display_name: "Missing ID"})

    assert %{"errors" => %{"external_id" => ["can't be blank"]}} = json_response(conn, 422)
  end

  test "creates a persistent stream for a creator", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-2"})

    conn = post(conn, "/api/control/streams", %{creator_id: creator.id, title: "Live Test"})

    assert %{"stream" => stream} = json_response(conn, 201)
    assert stream["creator_id"] == creator.id
    assert stream["title"] == "Live Test"
    assert stream["status"] == "offline"
  end

  test "rotates keys and revokes the previous key", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-3"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Key Test"})

    first_conn = post(conn, "/api/control/streams/#{stream.id}/keys")
    assert %{"stream_key" => %{"token" => first_token}} = json_response(first_conn, 200)

    second_conn = post(build_conn(), "/api/control/streams/#{stream.id}/keys")
    assert %{"stream_key" => %{"token" => second_token}} = json_response(second_conn, 200)
    assert first_token != second_token

    stream_id = stream.id
    assert Streams.authenticate_stream_key(first_token) == nil
    assert %{stream: %{id: ^stream_id}} = Streams.authenticate_stream_key(second_token)
  end

  test "returns not found when rotating a missing stream key", %{conn: conn} do
    conn = post(conn, "/api/control/streams/999999/keys")

    assert response(conn, 404) == ""
  end

  test "returns the playback URL for a live stream session", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-playback"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Playback Test"})
    {:ok, %{token: token}} = Streams.rotate_stream_key(stream)
    {:ok, session} = Zer0Stream.Ingest.authorize_rtmp(token, "playback-connection")

    conn = get(conn, "/api/streams/#{stream.id}/playback")
    assert %{"playback_url" => url, "session_id" => session_id} = json_response(conn, 200)
    assert session_id == session.id
    assert url =~ "/hls-boombox/stream-session-#{session.id}/master.m3u8?token="
  end

  test "does not return playback for an offline stream", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "creator-offline"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Offline Test"})

    conn = get(conn, "/api/streams/#{stream.id}/playback")
    assert response(conn, 404) == ""
  end
end
