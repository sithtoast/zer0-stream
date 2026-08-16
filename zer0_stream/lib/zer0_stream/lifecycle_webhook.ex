defmodule Zer0Stream.LifecycleWebhook do
  import Ecto.Query, only: [from: 2]
  import Bitwise

  require Logger

  alias Zer0Stream.{Repo, WebhookDelivery}

  @max_attempts 10

  def enqueue(event, data) when is_binary(event) and is_map(data) do
    case config() do
      nil ->
        :ok

      _config ->
        payload = event_payload(event, data)

        %WebhookDelivery{}
        |> WebhookDelivery.changeset(%{
          event_id: payload.id,
          event_type: event,
          payload: payload,
          next_attempt_at: DateTime.utc_now()
        })
        |> Repo.insert()
        |> case do
          {:ok, _delivery} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  def deliver_pending do
    case config() do
      nil ->
        :ok

      config ->
        now = DateTime.utc_now()

        deliveries =
          Repo.all(
            from(delivery in WebhookDelivery,
              where: delivery.status == "pending" and delivery.next_attempt_at <= ^now,
              order_by: [asc: delivery.inserted_at],
              limit: 20
            )
          )

        Enum.each(deliveries, &deliver_and_record(&1, config, now))
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

  defp deliver_and_record(delivery, config, now) do
    case deliver(config.url, config.secret, delivery.payload) do
      :ok ->
        delivery
        |> WebhookDelivery.changeset(%{status: "delivered", delivered_at: now, last_error: nil})
        |> Repo.update()

      {:error, reason} ->
        attempts = delivery.attempts + 1

        attrs =
          if attempts >= @max_attempts do
            %{status: "failed", attempts: attempts, last_error: inspect(reason)}
          else
            %{
              attempts: attempts,
              next_attempt_at: DateTime.add(now, retry_delay_seconds(attempts), :second),
              last_error: inspect(reason)
            }
          end

        delivery
        |> WebhookDelivery.changeset(attrs)
        |> Repo.update()
    end
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
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Lifecycle webhook delivery failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp retry_delay_seconds(attempts), do: min(1 <<< (attempts - 1), 300)

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
