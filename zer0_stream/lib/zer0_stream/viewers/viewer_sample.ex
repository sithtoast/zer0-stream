defmodule Zer0Stream.Viewers.ViewerSample do
  use Ecto.Schema

  import Ecto.Changeset

  schema "viewer_samples" do
    field(:viewer_count, :integer)
    field(:sampled_at, :utc_datetime)

    belongs_to(:stream, Zer0Stream.Streams.Stream)
    belongs_to(:stream_session, Zer0Stream.Streams.StreamSession)
    timestamps(type: :utc_datetime)
  end

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [:stream_id, :stream_session_id, :viewer_count, :sampled_at])
    |> validate_required([:stream_id, :stream_session_id, :viewer_count, :sampled_at])
    |> validate_number(:viewer_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:stream_id)
    |> foreign_key_constraint(:stream_session_id)
  end
end
