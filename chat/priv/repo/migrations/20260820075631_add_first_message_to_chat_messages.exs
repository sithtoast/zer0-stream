defmodule Chat.Repo.Migrations.AddFirstMessageToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :first_message, :boolean, null: false, default: false
    end
  end
end
