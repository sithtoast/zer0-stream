defmodule ChatWeb.UserSocket do
  use Phoenix.Socket

  channel "chat:*", ChatWeb.ChatChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_token(token) do
      {:ok, user} -> {:ok, assign(socket, :user, user)}
      :error -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil

  defp verify_token(token) when is_binary(token) do
    secret = Application.fetch_env!(:chat, :chat_token_secret)
    max_age = Application.get_env(:chat, :chat_token_max_age, 3600)

    # Tokens are scoped to one channel: the main app only issues one after
    # checking the viewer may chat there, so the channel and its broadcaster
    # come from the signed claims rather than from join params.
    case Phoenix.Token.verify(secret, "chat-user", token, max_age: max_age) do
      {:ok, %{"user_id" => user_id, "channel_id" => channel_id} = claims}
      when is_binary(channel_id) and channel_id != "" ->
        {:ok,
         %{
           id: user_id,
           display_name: Map.get(claims, "display_name"),
           channel_id: channel_id,
           broadcaster_id: Map.get(claims, "broadcaster_id")
         }}

      _ ->
        :error
    end
  end

  defp verify_token(_token), do: :error
end
