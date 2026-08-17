defmodule Zer0Stream.Repo.Migrations.AddCategoryToStreams do
  use Ecto.Migration

  def change do
    alter table(:streams) do
      add :category, :string
    end
  end
end
