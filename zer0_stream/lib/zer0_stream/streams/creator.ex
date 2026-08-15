defmodule Zer0Stream.Streams.Creator do
  use Ecto.Schema
  import Ecto.Changeset

  schema "creators" do
    field(:external_id, :string)
    field(:display_name, :string)

    has_many(:streams, Zer0Stream.Streams.Stream)
    timestamps(type: :utc_datetime)
  end

  def changeset(creator, attrs) do
    creator
    |> cast(attrs, [:external_id, :display_name])
    |> validate_required([:external_id])
    |> unique_constraint(:external_id)
  end
end
