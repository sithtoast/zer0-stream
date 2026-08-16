defmodule Zer0Stream.Repo.Migrations.CreateIdempotencyRecords do
  use Ecto.Migration

  def change do
    create table(:idempotency_records) do
      add :operation, :string, null: false
      add :request_id, :string, null: false
      add :resource_id, :bigint, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:idempotency_records, [:operation, :request_id])
  end
end