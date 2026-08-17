defmodule Zer0Stream.Repo.Migrations.ReplaceStreamCategoryWithTwitchReference do
  use Ecto.Migration

  def change do
    rename table(:streams), :category, to: :category_name

    alter table(:streams) do
      add :category_twitch_id, :string
    end

    create index(:streams, [:category_twitch_id])
  end
end
