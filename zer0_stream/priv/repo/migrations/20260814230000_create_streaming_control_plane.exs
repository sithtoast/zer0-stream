defmodule Zer0Stream.Repo.Migrations.CreateStreamingControlPlane do
  use Ecto.Migration

  def change do
    create table(:creators) do
      add(:external_id, :string, null: false)
      add(:display_name, :string)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:creators, [:external_id]))

    create table(:streams) do
      add(:title, :string, null: false)
      add(:status, :string, null: false, default: "offline")
      add(:creator_id, references(:creators, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:streams, [:creator_id]))
    create(index(:streams, [:status]))

    create table(:stream_keys) do
      add(:token_hash, :binary, null: false)
      add(:revoked_at, :utc_datetime)
      add(:creator_id, references(:creators, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:stream_keys, [:token_hash]))
    create(index(:stream_keys, [:creator_id]))
  end
end
