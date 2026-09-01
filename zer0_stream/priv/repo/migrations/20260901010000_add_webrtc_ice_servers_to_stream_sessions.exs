defmodule Zer0Stream.Repo.Migrations.AddWebrtcIceServersToStreamSessions do
  use Ecto.Migration

  def change do
    alter table(:stream_sessions) do
      add :webrtc_ice_servers, :map, null: true
    end
  end
end
