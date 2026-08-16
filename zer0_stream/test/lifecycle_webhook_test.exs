defmodule Zer0Stream.LifecycleWebhookTest do
  use ExUnit.Case

  alias Zer0Stream.{LifecycleWebhook, Repo, WebhookDelivery}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    previous_url = Application.get_env(:zer0_stream, :lifecycle_webhook_url)
    previous_secret = Application.get_env(:zer0_stream, :lifecycle_webhook_secret)
    Application.put_env(:zer0_stream, :lifecycle_webhook_url, "https://zer0.tv/api/stream-events")
    Application.put_env(:zer0_stream, :lifecycle_webhook_secret, "webhook-secret")

    on_exit(fn ->
      restore_config(:lifecycle_webhook_url, previous_url)
      restore_config(:lifecycle_webhook_secret, previous_secret)
    end)

    :ok
  end

  test "signs the exact JSON webhook body" do
    payload =
      LifecycleWebhook.event_payload(
        "stream.started",
        %{stream: %{id: 42}},
        ~U[2026-08-15 12:00:00Z]
      )

    request =
      LifecycleWebhook.signed_request(
        "https://zer0.tv/api/stream-events",
        "webhook-secret",
        payload,
        123
      )

    assert request.url == "https://zer0.tv/api/stream-events"
    assert {"x-zer0-timestamp", "123"} in request.headers

    {"x-zer0-signature", signature} = List.keyfind(request.headers, "x-zer0-signature", 0)

    expected =
      :crypto.mac(:hmac, :sha256, "webhook-secret", "123\n" <> request.body)
      |> Base.url_encode64(padding: false)

    assert signature == expected

    assert %{"type" => "stream.started", "data" => %{"stream" => %{"id" => 42}}} =
             Jason.decode!(request.body)
  end

  test "persists a pending delivery" do
    assert :ok = LifecycleWebhook.enqueue("stream.started", %{stream: %{id: 42}})

    delivery = Repo.one!(WebhookDelivery)
    assert delivery.event_type == "stream.started"
    assert delivery.status == "pending"
    assert delivery.attempts == 0
    assert delivery.payload["data"]["stream"]["id"] == 42
  end

  defp restore_config(key, nil), do: Application.delete_env(:zer0_stream, key)
  defp restore_config(key, value), do: Application.put_env(:zer0_stream, key, value)
end
