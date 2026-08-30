defmodule Zer0Stream.Repo.Migrations.AddLastActivityToStreamSessions do
  use Ecto.Migration

  def change do
    alter table(:stream_sessions) do
      add :last_activity_at, :utc_datetime
    end

    # Lets the periodic reconciler cheaply find stale live sessions.
    create index(:stream_sessions, [:status, :last_activity_at])
  end
end
