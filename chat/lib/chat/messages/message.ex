defmodule Chat.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :channel_id, :string
    field :sender_id, :string
    field :sender_display_name, :string
    field :body, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:channel_id, :sender_id, :sender_display_name, :body])
    |> validate_required([:channel_id, :sender_id, :body])
    |> validate_length(:body, max: 500)
  end
end
