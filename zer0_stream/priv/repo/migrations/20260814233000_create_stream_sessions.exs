defmodule Zer0Stream.Repo.Migrations.CreateStreamSessions do
  use Ecto.Migration

  def change do
    create table(:stream_sessions) do
      add :connection_id, :string, null: false
      add :protocol, :string, null: false, default: "rtmp"
      add :status, :string, null: false, default: "live"
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :stream_id, references(:streams, on_delete: :delete_all), null: false
      add :stream_key_id, references(:stream_keys, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:stream_sessions, [:connection_id])
    create index(:stream_sessions, [:stream_id, :status])
  end
end
