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
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end
end
