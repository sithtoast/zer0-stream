defmodule Zer0Stream.Ingest.RTMPAdapterTest do
  use ExUnit.Case

  alias Zer0Stream.{Ingest, Streams}
  alias Zer0Stream.Ingest.RTMPAdapter

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Zer0Stream.Repo)

    {:ok, creator} = Streams.create_creator(%{external_id: "adapter-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Adapter Test"})
    {:ok, %{token: token}} = Streams.rotate_stream_key(stream)

    {:ok, stream: stream, token: token}
  end

  test "authorizes connection metadata through the ingest boundary", %{token: token} do
    assert {:ok, session} =
             RTMPAdapter.authorize(%{stream_key: token, connection_id: "adapter-1"})

    assert session.protocol == "rtmp"
    assert session.status == "live"
  end

  test "rejects malformed adapter input" do
    assert {:error, :invalid_request} = RTMPAdapter.authorize(%{})
    assert {:error, :invalid_request} = RTMPAdapter.disconnect(nil)
  end

  test "disconnects a live connection", %{stream: stream, token: token} do
    assert {:ok, _session} = Ingest.authorize_rtmp(token, "adapter-2")
    assert {:ok, %{status: "ended"}} = RTMPAdapter.disconnect("adapter-2")
    assert %{status: "offline"} = Streams.get_stream(stream.id)
  end
end
