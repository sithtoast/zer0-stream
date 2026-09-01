defmodule Zer0Stream.Streams.StreamSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stream_sessions" do
    field(:connection_id, :string)
    field(:protocol, :string, default: "rtmp")
    field(:status, :string, default: "live")
    field(:started_at, :utc_datetime)
    field(:ended_at, :utc_datetime)
    field(:last_activity_at, :utc_datetime)
    field(:webrtc_url, :string)
    field(:webrtc_ice_servers, :map)

    belongs_to(:stream, Zer0Stream.Streams.Stream)
    belongs_to(:stream_key, Zer0Stream.Streams.StreamKey)
    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :connection_id,
      :protocol,
      :status,
      :started_at,
      :last_activity_at,
      :stream_id,
      :stream_key_id,
      :webrtc_url,
      :webrtc_ice_servers
    ])
    |> validate_required([:connection_id, :protocol, :status, :stream_id, :stream_key_id])
    |> validate_inclusion(:protocol, ["rtmp"])
    |> validate_inclusion(:status, ["live", "ended"])
    |> unique_constraint(:connection_id)
    |> foreign_key_constraint(:stream_id)
    |> foreign_key_constraint(:stream_key_id)
  end
end
