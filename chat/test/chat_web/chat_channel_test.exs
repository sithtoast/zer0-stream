defmodule ChatWeb.ChatChannelTest do
  use ChatWeb.ChannelCase, async: false

  alias Chat.Messages

  setup do
    token =
      Phoenix.Token.sign(
        Application.fetch_env!(:chat, :chat_token_secret),
        "chat-user",
        %{"user_id" => "user-1", "display_name" => "Ada"}
      )

    raw_socket = socket(ChatWeb.UserSocket, "socket-id", %{"token" => token})
    {:ok, authenticated_socket} = ChatWeb.UserSocket.connect(%{"token" => token}, raw_socket, %{})

    {:ok, _join_reply, socket} =
      subscribe_and_join(authenticated_socket, ChatWeb.ChatChannel, "chat:test-channel")

    %{socket: socket}
  end

  test "joins with recent message history", %{socket: socket} do
    assert socket.assigns.channel_id == "test-channel"
  end

  test "persists and broadcasts messages", %{socket: socket} do
    push(socket, "message", %{"body" => "hello"})
    assert_push "message", %{body: "hello", channel_id: "test-channel"}

    assert [%{body: "hello", sender_id: "user-1"}] = Messages.recent("test-channel")
  end

  test "flags a user's first message in a channel", %{socket: socket} do
    push(socket, "message", %{"body" => "hello"})
    assert_push "message", %{body: "hello", first_message: true}

    push(socket, "message", %{"body" => "hello again"})
    assert_push "message", %{body: "hello again", first_message: false}
  end

  test "rejects empty and oversized messages", %{socket: socket} do
    empty_ref = push(socket, "message", %{"body" => "   "})
    assert_reply empty_ref, :error, %{reason: "empty_message"}

    oversized_ref = push(socket, "message", %{"body" => String.duplicate("x", 501)})
    assert_reply oversized_ref, :error, %{reason: "message_too_long", max_length: 500}
  end

  test "rate limits messages per connection", %{socket: socket} do
    for _attempt <- 1..10 do
      push(socket, "message", %{"body" => "hello"})
      assert_push "message", %{body: "hello"}
    end

    ref = push(socket, "message", %{"body" => "blocked"})
    assert_reply ref, :error, %{reason: "rate_limited"}
  end
end
