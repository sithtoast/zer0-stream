defmodule Zer0Stream.Repo.Migrations.AddWebrtcUrlToStreamSessions do
  use Ecto.Migration

  def change do
    alter table(:stream_sessions) do
      add :webrtc_url, :text, null: true
    end
  end
end
