defmodule ChatWeb.ChatChannel do
  use ChatWeb, :channel

  alias Chat.Messages
  alias ChatWeb.Presence

  @max_message_length 500
  @max_messages_per_window 10
  @rate_limit_window_ms 10_000

  @impl true
  def join("chat:" <> channel_id, params, socket) when channel_id != "" do
    # The broadcaster's Twitch user id is passed by the frontend on join so we
    # can label that sender's messages with a broadcaster badge.
    broadcaster_id = params["broadcaster_id"]
    messages = Messages.recent(channel_id)

    socket =
      socket
      |> assign(:channel_id, channel_id)
      |> assign(:broadcaster_id, broadcaster_id)
      |> assign(:message_timestamps, [])

    send(self(), :after_join)
    {:ok, %{messages: Enum.map(messages, &message_payload(&1, broadcaster_id))}, socket}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "invalid_channel"}}

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(socket, socket.assigns.user.id, %{
        display_name: socket.assigns.user.display_name
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_in("message", %{"body" => body} = params, socket) when is_binary(body) do
    body = String.trim(body)
    gif_slug = params["gif_slug"]

    cond do
      not valid_gif_slug?(gif_slug) ->
        {:reply, {:error, %{reason: "invalid_gif"}}, socket}

      body == "" and is_nil(gif_slug) ->
        {:reply, {:error, %{reason: "empty_message"}}, socket}

      String.length(body) > @max_message_length ->
        {:reply, {:error, %{reason: "message_too_long", max_length: @max_message_length}}, socket}

      true ->
        case allow_message?(socket) do
          {:error, socket} ->
            {:reply, {:error, %{reason: "rate_limited"}}, socket}

          {:ok, socket} ->
            attrs = %{
              channel_id: socket.assigns.channel_id,
              sender_id: socket.assigns.user.id,
              sender_display_name: socket.assigns.user.display_name,
              body: body,
              gif_slug: gif_slug
            }

            case Messages.create_message(attrs) do
              {:ok, message} ->
                payload = message_payload(message, socket.assigns.broadcaster_id)
                broadcast!(socket, "message", payload)
                # Acknowledge the sender so the client doesn't hit its push timeout.
                {:reply, {:ok, payload}, socket}

              {:error, _changeset} ->
                {:reply, {:error, %{reason: "message_not_saved"}}, socket}
            end
        end
    end
  end

  def handle_in("message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  defp valid_gif_slug?(nil), do: true

  defp valid_gif_slug?(slug) when is_binary(slug) and byte_size(slug) in 1..200,
    do: Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, slug)

  defp valid_gif_slug?(_), do: false

  defp allow_message?(socket) do
    now = System.monotonic_time(:millisecond)

    timestamps =
      socket.assigns.message_timestamps
      |> Enum.filter(&(&1 > now - @rate_limit_window_ms))

    if length(timestamps) >= @max_messages_per_window do
      {:error, assign(socket, :message_timestamps, timestamps)}
    else
      {:ok, assign(socket, :message_timestamps, [now | timestamps])}
    end
  end

  defp message_payload(message, broadcaster_id) do
    %{
      id: message.id,
      body: message.body,
      gif_slug: message.gif_slug,
      channel_id: message.channel_id,
      first_message: message.first_message,
      is_broadcaster: message.sender_id == broadcaster_id,
      sender: %{
        id: message.sender_id,
        display_name: message.sender_display_name
      },
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end
end
