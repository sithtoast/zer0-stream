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

  test "tracks quiet room members and broadcasts their departure", %{socket: socket} do
    Process.flag(:trap_exit, true)
    assert_push "presence_state", %{"user-1" => %{metas: [%{display_name: "Ada"} | _]}}

    {:ok, _, quiet_socket} =
      socket(ChatWeb.UserSocket, "quiet-socket", %{user: %{id: "quiet", display_name: "Quiet"}})
      |> subscribe_and_join(ChatWeb.ChatChannel, socket.topic)

    assert_broadcast "presence_diff",
                     %{joins: %{"quiet" => %{metas: [%{display_name: "Quiet"}]}}},
                     1_000

    assert Messages.recent(socket.assigns.channel_id) == []

    ref = leave(quiet_socket)
    assert_reply ref, :ok
    assert_broadcast "presence_diff", %{leaves: %{"quiet" => %{metas: [_]}}}, 1_000
    refute Map.has_key?(ChatWeb.Presence.list(socket), "quiet")
  end

  test "presence is scoped to the room and retains other connections", %{socket: socket} do
    Process.flag(:trap_exit, true)
    assert_push "presence_state", %{"user-1" => _}

    {:ok, _, second_tab} =
      socket(ChatWeb.UserSocket, "second-tab", %{user: %{id: "multi", display_name: "Multi"}})
      |> subscribe_and_join(ChatWeb.ChatChannel, socket.topic)

    assert_broadcast "presence_diff", %{joins: %{"multi" => _}}, 1_000

    {:ok, _, third_tab} =
      socket(ChatWeb.UserSocket, "third-tab", %{user: %{id: "multi", display_name: "Multi"}})
      |> subscribe_and_join(ChatWeb.ChatChannel, socket.topic)

    assert_broadcast "presence_diff", %{joins: %{"multi" => _}}, 1_000
    assert %{metas: [_, _]} = ChatWeb.Presence.list(socket)["multi"]

    {:ok, _, other_room} =
      socket(ChatWeb.UserSocket, "other-room", %{user: %{id: "other", display_name: "Other"}})
      |> subscribe_and_join(ChatWeb.ChatChannel, "chat:other-room")

    assert_push "presence_state", %{"other" => _}
    refute Map.has_key?(ChatWeb.Presence.list(socket), "other")
    refute Map.has_key?(ChatWeb.Presence.list(other_room), "multi")

    ref = leave(second_tab)
    assert_reply ref, :ok
    assert_broadcast "presence_diff", %{leaves: %{"multi" => _}}, 1_000
    assert %{metas: [_]} = ChatWeb.Presence.list(socket)["multi"]

    ref = leave(third_tab)
    assert_reply ref, :ok
    assert_broadcast "presence_diff", %{leaves: %{"multi" => _}}, 1_000
    refute Map.has_key?(ChatWeb.Presence.list(socket), "multi")
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

  test "persists GIF-only messages and includes them in reconnect history", %{socket: socket} do
    ref = push(socket, "message", %{"body" => "", "gif_slug" => "hello-hi-662"})
    assert_reply ref, :ok, %{gif_slug: "hello-hi-662"}
    assert_push "message", %{gif_slug: "hello-hi-662", first_message: true}
    assert [%{body: nil, gif_slug: "hello-hi-662"}] = Messages.recent("test-channel")

    {:ok, %{messages: [message]}, _} =
      socket(ChatWeb.UserSocket, "reconnect", %{user: %{id: "user-2", display_name: "Bob"}})
      |> subscribe_and_join(ChatWeb.ChatChannel, "chat:test-channel")

    assert message.gif_slug == "hello-hi-662"
  end

  test "preserves captions and rejects malformed GIF identifiers", %{socket: socket} do
    ref = push(socket, "message", %{"body" => "hello @Ada", "gif_slug" => "hello-hi-662"})
    assert_reply ref, :ok, %{body: "hello @Ada", gif_slug: "hello-hi-662"}

    for slug <- [
          "",
          "https://evil.test/a.gif",
          "../x",
          "hi\n",
          %{},
          123,
          String.duplicate("a", 201)
        ] do
      ref = push(socket, "message", %{"body" => "caption", "gif_slug" => slug})
      assert_reply ref, :error, %{reason: "invalid_gif"}
    end

    assert length(Messages.recent("test-channel")) == 1
  end

  test "GIFs share the message rate limit", %{socket: socket} do
    for _ <- 1..10 do
      ref = push(socket, "message", %{"body" => "", "gif_slug" => "hello"})
      assert_reply ref, :ok
    end

    ref = push(socket, "message", %{"body" => "", "gif_slug" => "hello"})
    assert_reply ref, :error, %{reason: "rate_limited"}
  end
end
