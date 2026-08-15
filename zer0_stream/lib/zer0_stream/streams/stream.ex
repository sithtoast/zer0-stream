defmodule Zer0Stream.Streams.Stream do
  use Ecto.Schema
  import Ecto.Changeset

  schema "streams" do
    field(:title, :string)
    field(:status, :string, default: "offline")

    belongs_to(:creator, Zer0Stream.Streams.Creator)
    has_many(:stream_keys, Zer0Stream.Streams.StreamKey)
    timestamps(type: :utc_datetime)
  end

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [:title, :status, :creator_id])
    |> validate_required([:title, :creator_id])
    |> validate_inclusion(:status, ~w(offline live))
    |> foreign_key_constraint(:creator_id)
  end
end
