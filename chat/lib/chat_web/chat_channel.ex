defmodule ChatWeb.ChatChannel do
  use ChatWeb, :channel

  alias Chat.Messages

  @max_message_length 500
  @max_messages_per_window 10
  @rate_limit_window_ms 10_000

  @impl true
  def join("chat:" <> channel_id, _params, socket) when channel_id != "" do
    messages = Messages.recent(channel_id)

    socket =
      socket
      |> assign(:channel_id, channel_id)
      |> assign(:message_timestamps, [])

    {:ok, %{messages: Enum.map(messages, &message_payload/1)}, socket}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "invalid_channel"}}

  @impl true
  def handle_in("message", %{"body" => body}, socket) when is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" ->
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
              body: body
            }

            case Messages.create_message(attrs) do
              {:ok, message} ->
                broadcast!(socket, "message", message_payload(message))
                {:noreply, socket}

              {:error, _changeset} ->
                {:reply, {:error, %{reason: "message_not_saved"}}, socket}
            end
        end
    end
  end

  def handle_in("message", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

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

  defp message_payload(message) do
    %{
      id: message.id,
      body: message.body,
      channel_id: message.channel_id,
      first_message: message.first_message,
      sender: %{
        id: message.sender_id,
        display_name: message.sender_display_name
      },
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end
end
