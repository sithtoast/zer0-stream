defmodule Zer0Stream.Repo.Migrations.CreateStreamUpdates do
  use Ecto.Migration

  def change do
    create table(:stream_updates) do
      add :stream_id, references(:streams, on_delete: :delete_all), null: false
      add :session_id, references(:stream_sessions, on_delete: :nilify_all)
      add :title, :string
      add :category_name, :string
      add :category_twitch_id, :string
      add :changed_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:stream_updates, [:stream_id])
    create index(:stream_updates, [:session_id])
  end
end
