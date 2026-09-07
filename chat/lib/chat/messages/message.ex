defmodule Chat.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :channel_id, :string
    field :sender_id, :string
    field :sender_display_name, :string
    field :body, :string
    field :gif_slug, :string
    field :first_message, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:channel_id, :sender_id, :sender_display_name, :body, :gif_slug])
    |> validate_required([:channel_id, :sender_id])
    |> validate_length(:body, max: 500)
    |> validate_length(:gif_slug, max: 200)
    |> validate_format(:gif_slug, ~r/\A[a-zA-Z0-9_-]+\z/)
    |> require_content()
  end

  defp require_content(changeset) do
    if get_field(changeset, :body) || get_field(changeset, :gif_slug),
      do: changeset,
      else: add_error(changeset, :body, "cannot be empty without a GIF")
  end
end
