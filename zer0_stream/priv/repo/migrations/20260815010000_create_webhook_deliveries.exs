defmodule Zer0Stream.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime, null: false
      add :delivered_at, :utc_datetime
      add :last_error, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhook_deliveries, [:event_id])
    create index(:webhook_deliveries, [:status, :next_attempt_at])
  end
end