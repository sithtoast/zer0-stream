defmodule Zer0Stream.Streams.StreamUpdate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stream_updates" do
    field(:title, :string)
    field(:category_name, :string)
    field(:category_twitch_id, :string)
    field(:changed_at, :utc_datetime)

    belongs_to(:stream, Zer0Stream.Streams.Stream)
    belongs_to(:session, Zer0Stream.Streams.StreamSession, foreign_key: :session_id)
    timestamps(type: :utc_datetime)
  end

  def changeset(update, attrs) do
    update
    |> cast(attrs, [
      :stream_id,
      :session_id,
      :title,
      :category_name,
      :category_twitch_id,
      :changed_at
    ])
    |> validate_required([:stream_id, :changed_at])
    |> foreign_key_constraint(:stream_id)
    |> foreign_key_constraint(:session_id)
  end
end
