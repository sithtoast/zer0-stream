defmodule Chat.Messages do
  import Ecto.Query

  alias Chat.Messages.Message
  alias Chat.Repo

  @recent_limit 50

  def recent(channel_id, limit \\ @recent_limit) do
    safe_limit = min(max(limit, 1), @recent_limit)

    Message
    |> where([message], message.channel_id == ^channel_id)
    |> order_by([message], desc: message.inserted_at)
    |> limit(^safe_limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def create_message(attrs) do
    channel_id = attrs[:channel_id] || attrs["channel_id"]
    sender_id = attrs[:sender_id] || attrs["sender_id"]

    %Message{}
    |> Message.changeset(attrs)
    |> Ecto.Changeset.put_change(:first_message, first_message?(channel_id, sender_id))
    |> Repo.insert()
  end

  defp first_message?(channel_id, sender_id) when is_binary(channel_id) and is_binary(sender_id) do
    Message
    |> where([message], message.channel_id == ^channel_id and message.sender_id == ^sender_id)
    |> Repo.exists?()
    |> Kernel.not()
  end

  defp first_message?(_channel_id, _sender_id), do: false
end
