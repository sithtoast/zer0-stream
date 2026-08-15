defmodule Zer0Stream.IngestTest do
  use ExUnit.Case

  alias Zer0Stream.{Ingest, Streams}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Zer0Stream.Repo)

    {:ok, creator} = Streams.create_creator(%{external_id: "ingest-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Ingest Test"})
    {:ok, %{token: token}} = Streams.rotate_stream_key(stream)

    {:ok, stream: stream, token: token}
  end

  test "authorizes an RTMP connection and marks its stream live", %{stream: stream, token: token} do
    assert {:ok, session} = Ingest.authorize_rtmp(token, "connection-1")
    assert session.connection_id == "connection-1"
    assert session.protocol == "rtmp"
    assert session.status == "live"

    assert %{status: "live"} = Streams.get_stream(stream.id)
  end

  test "rejects revoked or invalid keys", %{stream: stream, token: token} do
    assert {:error, :unauthorized} = Ingest.authorize_rtmp("invalid-key", "connection-2")

    assert {:ok, %{token: replacement}} = Streams.rotate_stream_key(stream)
    assert {:error, :unauthorized} = Ingest.authorize_rtmp(token, "connection-3")
    assert {:ok, _session} = Ingest.authorize_rtmp(replacement, "connection-4")
  end

  test "stops a connection and marks the stream offline", %{stream: stream, token: token} do
    assert {:ok, _session} = Ingest.authorize_rtmp(token, "connection-5")
    assert {:ok, %{status: "ended"}} = Ingest.stop_session("connection-5")
    assert %{status: "offline"} = Streams.get_stream(stream.id)
  end
end
