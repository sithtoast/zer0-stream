defmodule Zer0Stream.LifecycleWebhook do
  require Logger

  def emit(event, data) when is_binary(event) and is_map(data) do
    case config() do
      nil ->
        :ok

      %{url: url, secret: secret} ->
        payload = event_payload(event, data)

        Task.Supervisor.start_child(Zer0Stream.WebhookTaskSupervisor, fn ->
          deliver(url, secret, payload)
        end)
    end
  end

  def event_payload(event, data, occurred_at \\ DateTime.utc_now()) do
    %{
      id: event_id(),
      type: event,
      occurred_at: DateTime.to_iso8601(occurred_at),
      data: data
    }
  end

  def signed_request(url, secret, payload, timestamp \\ System.system_time(:second)) do
    body = Jason.encode!(payload)
    timestamp = Integer.to_string(timestamp)
    signature = sign(secret, timestamp, body)

    %{
      url: url,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"x-zer0-timestamp", timestamp},
        {"x-zer0-signature", signature}
      ]
    }
  end

  defp deliver(url, secret, payload) do
    %{body: body, headers: headers} = signed_request(url, secret, payload)

    request = {
      String.to_charlist(url),
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end),
      ~c"application/json",
      body
    }

    case :httpc.request(:post, request, [timeout: 5_000], []) do
      {:ok, {{_, status, _}, _headers, _response_body}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _headers, _response_body}} ->
        Logger.warning("Lifecycle webhook delivery failed with status #{status}")

      {:error, reason} ->
        Logger.warning("Lifecycle webhook delivery failed: #{inspect(reason)}")
    end
  end

  defp config do
    case Application.get_env(:zer0_stream, :lifecycle_webhook_url) do
      url when is_binary(url) and byte_size(url) > 0 ->
        %{url: url, secret: Application.fetch_env!(:zer0_stream, :lifecycle_webhook_secret)}

      _ ->
        nil
    end
  end

  defp sign(secret, timestamp, body) do
    :crypto.mac(:hmac, :sha256, secret, timestamp <> "\n" <> body)
    |> Base.url_encode64(padding: false)
  end

  defp event_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
