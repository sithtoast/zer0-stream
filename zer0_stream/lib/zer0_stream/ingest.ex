defmodule Zer0Stream.Ingest do
  import Ecto.Query, only: [from: 2]

  alias Zer0Stream.Repo
  alias Zer0Stream.Streams
  alias Zer0Stream.Streams.{Stream, StreamSession}

  def authorize_rtmp(stream_key, connection_id)
      when is_binary(stream_key) and is_binary(connection_id) do
    case Streams.authenticate_stream_key(stream_key) do
      nil ->
        {:error, :unauthorized}

      %{stream: %Stream{} = stream, id: stream_key_id} ->
        case start_session(stream, stream_key_id, connection_id) do
          {:ok, {session, :started}} ->
            emit_stream_started(session)
            {:ok, session}

          {:ok, session, :existing} ->
            {:ok, session}

          error ->
            error
        end
    end
  end

  def stop_session(connection_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(StreamSession, connection_id: connection_id, status: "live") do
             nil ->
               Repo.rollback(:not_found)

             session ->
               ended_at = DateTime.utc_now()

               {:ok, session} =
                 session
                 |> StreamSession.changeset(%{status: "ended", ended_at: ended_at})
                 |> Repo.update()

               stream_stopped? =
                 not Repo.exists?(
                   from(s in StreamSession,
                     where: s.stream_id == ^session.stream_id and s.status == "live"
                   )
                 )

               if stream_stopped? do
                 Repo.update_all(from(s in Stream, where: s.id == ^session.stream_id),
                   set: [status: "offline"]
                 )
               end

               {Repo.preload(session, stream: :creator), stream_stopped?}
           end
         end) do
      {:ok, {session, true}} ->
        emit_stream_stopped(session)
        {:ok, session}

      {:ok, {session, false}} ->
        {:ok, session}

      error ->
        error
    end
  end

  def reconcile_sessions do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {ended_count, _} =
        Repo.update_all(
          from(session in StreamSession, where: session.status == "live"),
          set: [status: "ended", ended_at: now, updated_at: now]
        )

      Repo.update_all(from(stream in Stream, where: stream.status == "live"),
        set: [status: "offline", updated_at: now]
      )

      ended_count
    end)
  end

  defp start_session(stream, stream_key_id, connection_id) do
    now = DateTime.utc_now()

    case Repo.get_by(StreamSession, connection_id: connection_id) do
      %StreamSession{status: "live"} = session ->
        {:ok, Repo.preload(session, stream: :creator), :existing}

      nil ->
        Repo.transaction(fn ->
          {:ok, session} =
            %StreamSession{}
            |> StreamSession.changeset(%{
              connection_id: connection_id,
              protocol: "rtmp",
              status: "live",
              started_at: now,
              stream_id: stream.id,
              stream_key_id: stream_key_id
            })
            |> Repo.insert()

          Repo.update_all(from(s in Stream, where: s.id == ^stream.id), set: [status: "live"])
          {Repo.preload(session, stream: :creator), :started}
        end)

      %StreamSession{status: "ended"} ->
        {:error, :connection_id_reused}
    end
  end

  defp emit_stream_started(session) do
    Zer0Stream.LifecycleWebhook.emit("stream.started", stream_event_data(session))
  end

  defp emit_stream_stopped(session) do
    Zer0Stream.LifecycleWebhook.emit("stream.stopped", stream_event_data(session))
  end

  defp stream_event_data(session) do
    %{
      stream: %{
        id: session.stream.id,
        creator_id: session.stream.creator_id,
        title: session.stream.title,
        status: session.stream.status
      },
      session: %{
        id: session.id,
        connection_id: session.connection_id,
        protocol: session.protocol,
        status: session.status,
        started_at: session.started_at,
        ended_at: session.ended_at
      }
    }
  end
end
