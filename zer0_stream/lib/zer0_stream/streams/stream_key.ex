defmodule Zer0Stream.Streams.StreamKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stream_keys" do
    field(:token_hash, :binary)
    field(:revoked_at, :utc_datetime)

    belongs_to(:creator, Zer0Stream.Streams.Creator)
    timestamps(type: :utc_datetime)
  end

  def changeset(stream_key, attrs) do
    stream_key
    |> cast(attrs, [:token_hash, :creator_id, :revoked_at])
    |> validate_required([:token_hash, :creator_id])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:creator_id)
  end

  def hash_token(token), do: :crypto.hash(:sha256, token)
end
