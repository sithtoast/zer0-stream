defmodule Chat.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages) do
      add :channel_id, :string, null: false
      add :sender_id, :string, null: false
      add :sender_display_name, :string
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:chat_messages, [:channel_id, :inserted_at])
  end
end
