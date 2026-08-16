defmodule Zer0Stream.LifecycleWebhookTest do
  use ExUnit.Case, async: true

  alias Zer0Stream.LifecycleWebhook

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
end
