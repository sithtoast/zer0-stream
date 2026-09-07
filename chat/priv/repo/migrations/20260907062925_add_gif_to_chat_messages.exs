defmodule Chat.Repo.Migrations.AddGifToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :gif_slug, :string
      modify :body, :text, null: true, from: {:text, null: false}
    end
  end
end
