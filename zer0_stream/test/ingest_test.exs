defmodule Zer0Stream.IngestTest do
  use ExUnit.Case

  import Ecto.Query

  alias Zer0Stream.{Ingest, Repo, Streams, WebhookDelivery}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Zer0Stream.Repo)

    {:ok, creator} = Streams.create_creator(%{external_id: "ingest-creator"})
    {:ok, stream} = Streams.create_stream(%{creator_id: creator.id, title: "Ingest Test"})
    {:ok, %{token: token}} = Streams.rotate_creator_stream_key(creator)

    {:ok, stream: stream, token: token}
  end

  test "authorizes an RTMP connection and marks its stream live", %{stream: stream, token: token} do
    assert {:ok, session} = Ingest.authorize_rtmp(token, "connection-1")
    assert session.connection_id == "connection-1"
    assert session.protocol == "rtmp"
    assert session.status == "live"

    assert %{status: "live"} = Streams.get_stream(stream.id)
  end

  test "allows only one channel stream per creator", %{stream: stream} do
    assert {:error, changeset} =
             Streams.create_stream(%{creator_id: stream.creator_id, title: "Second Channel"})

    assert "has already been taken" in errors_on(changeset).creator_id
  end

  test "enqueues a started event with the session transition", %{token: token} do
    previous_url = Application.get_env(:zer0_stream, :lifecycle_webhook_url)
    previous_secret = Application.get_env(:zer0_stream, :lifecycle_webhook_secret)
    Application.put_env(:zer0_stream, :lifecycle_webhook_url, "https://zer0.tv/api/stream-events")
    Application.put_env(:zer0_stream, :lifecycle_webhook_secret, "webhook-secret")

    on_exit(fn ->
      restore_config(:lifecycle_webhook_url, previous_url)
      restore_config(:lifecycle_webhook_secret, previous_secret)
    end)

    assert {:ok, _session} = Ingest.authorize_rtmp(token, "connection-outbox")

    assert %WebhookDelivery{event_type: "stream.started", status: "pending"} =
             Repo.one!(WebhookDelivery)
  end

  test "rejects revoked or invalid keys", %{stream: stream, token: token} do
    assert {:error, :unauthorized} = Ingest.authorize_rtmp("invalid-key", "connection-2")

    creator = Streams.get_creator!(stream.creator_id)
    assert {:ok, %{token: replacement}} = Streams.rotate_creator_stream_key(creator)
    assert {:error, :unauthorized} = Ingest.authorize_rtmp(token, "connection-3")
    assert {:ok, _session} = Ingest.authorize_rtmp(replacement, "connection-4")
  end

  test "stops a connection and marks the stream offline", %{stream: stream, token: token} do
    assert {:ok, _session} = Ingest.authorize_rtmp(token, "connection-5")
    assert {:ok, %{status: "ended"}} = Ingest.stop_session("connection-5")
    assert %{status: "offline"} = Streams.get_stream(stream.id)
  end

  test "reconciliation enqueues a stopped event", %{token: token} do
    previous_url = Application.get_env(:zer0_stream, :lifecycle_webhook_url)
    previous_secret = Application.get_env(:zer0_stream, :lifecycle_webhook_secret)
    Application.put_env(:zer0_stream, :lifecycle_webhook_url, "https://zer0.tv/api/stream-events")
    Application.put_env(:zer0_stream, :lifecycle_webhook_secret, "webhook-secret")

    on_exit(fn ->
      restore_config(:lifecycle_webhook_url, previous_url)
      restore_config(:lifecycle_webhook_secret, previous_secret)
    end)

    assert {:ok, _session} = Ingest.authorize_rtmp(token, "connection-reconcile")
    assert {:ok, 1} = Ingest.reconcile_sessions()

    assert 2 == Repo.aggregate(WebhookDelivery, :count)

    assert %WebhookDelivery{event_type: "stream.stopped"} =
             Repo.one(
               from(delivery in WebhookDelivery, where: delivery.event_type == "stream.stopped")
             )
  end

  defp restore_config(key, nil), do: Application.delete_env(:zer0_stream, key)
  defp restore_config(key, value), do: Application.put_env(:zer0_stream, key, value)

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
