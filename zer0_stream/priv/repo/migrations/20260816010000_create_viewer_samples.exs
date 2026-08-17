defmodule Zer0Stream.Repo.Migrations.CreateViewerSamples do
  use Ecto.Migration

  def change do
    create table(:viewer_samples) do
      add(:stream_id, references(:streams, on_delete: :delete_all), null: false)
      add(:stream_session_id, references(:stream_sessions, on_delete: :delete_all), null: false)
      add(:viewer_count, :integer, null: false)
      add(:sampled_at, :utc_datetime, null: false)
      timestamps(type: :utc_datetime)
    end

    create(index(:viewer_samples, [:stream_id, :sampled_at]))
    create(index(:viewer_samples, [:stream_session_id, :sampled_at]))

    create(
      constraint(:viewer_samples, :viewer_samples_viewer_count_non_negative,
        check: "viewer_count >= 0"
      )
    )
  end
end
