defmodule Zer0StreamWeb.IngestControllerTest do
  use Zer0StreamWeb.ConnCase

  alias Zer0Stream.Streams

  test "authorizes an RTMP connection with a valid stream key", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "http-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "HTTP Ingest"})
    {:ok, %{token: token}} = Streams.rotate_stream_key(stream)

    conn =
      post(conn, "/api/ingest/rtmp/authorize", %{
        stream_key: token,
        connection_id: "http-connection-1"
      })

    assert %{"session" => session, "stream" => response_stream} = json_response(conn, 201)
    assert session["connection_id"] == "http-connection-1"
    assert session["protocol"] == "rtmp"
    assert response_stream["title"] == "HTTP Ingest"
  end

  test "rejects an invalid RTMP stream key", %{conn: conn} do
    conn =
      post(conn, "/api/ingest/rtmp/authorize", %{
        stream_key: "invalid-key",
        connection_id: "http-connection-2"
      })

    assert json_response(conn, 401) == %{"error" => "invalid stream key"}
  end

  test "stops an RTMP connection", %{conn: conn} do
    {:ok, creator} = Streams.create_creator(%{external_id: "http-stop-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "HTTP Stop"})
    {:ok, %{token: token}} = Streams.rotate_stream_key(stream)

    post(conn, "/api/ingest/rtmp/authorize", %{
      stream_key: token,
      connection_id: "http-connection-3"
    })

    conn = post(build_conn(), "/api/ingest/rtmp/http-connection-3/stop")

    assert %{"session" => %{"status" => "ended"}} = json_response(conn, 200)
  end
end
