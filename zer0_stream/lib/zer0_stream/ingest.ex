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

      %{creator_id: creator_id, id: stream_key_id} ->
        with %Stream{} = stream <- Streams.get_stream_for_creator(creator_id) do
          case start_session(stream, stream_key_id, connection_id) do
            {:ok, {session, :started}} -> {:ok, session}
            {:ok, session, :existing} -> {:ok, session}
            error -> error
          end
        else
          nil -> {:error, :unauthorized}
        end
    end
  end

  def stop_session(connection_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(StreamSession, connection_id: connection_id, status: "live") do
             nil ->
               Repo.rollback(:not_found)

             session ->
               end_session(session, DateTime.utc_now())
           end
         end) do
      {:ok, {session, _stream_stopped?}} -> {:ok, session}
      error -> error
    end
  end

  def reconcile_sessions do
    now = DateTime.utc_now()

    sessions =
      Repo.all(
        from(session in StreamSession,
          where: session.status == "live",
          preload: [stream: :creator]
        )
      )

    Enum.each(sessions, fn session -> end_session(session, now) end)
    {:ok, length(sessions)}
  end

  @doc """
  Ends any live session whose last activity is older than `stale_after` seconds
  (or that has never recorded activity). Returns the number of sessions ended.
  """
  def reconcile_stale_sessions(stale_after_seconds \\ stale_after_seconds()) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -stale_after_seconds, :second)

    sessions =
      Repo.all(
        from(session in StreamSession,
          where:
            session.status == "live" and
              (is_nil(session.last_activity_at) or session.last_activity_at < ^cutoff),
          preload: [stream: :creator]
        )
      )

    Enum.each(sessions, fn session -> end_session(session, now) end)
    length(sessions)
  end

  def heartbeat(session_id) do
    case Repo.get_by(StreamSession, id: session_id, status: "live") do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Ecto.Changeset.change(last_activity_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
        |> case do
          {:ok, _session} -> :ok
          error -> error
        end
    end
  end

  defp start_session(stream, stream_key_id, connection_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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
              last_activity_at: now,
              stream_id: stream.id,
              stream_key_id: stream_key_id
            })
            |> Repo.insert()

          Repo.update_all(from(s in Stream, where: s.id == ^stream.id), set: [status: "live"])
          session = Repo.preload(session, stream: :creator)
          :ok = Zer0Stream.LifecycleWebhook.enqueue("stream.started", stream_event_data(session))
          {session, :started}
        end)

      %StreamSession{status: "ended"} ->
        {:error, :connection_id_reused}
    end
  end

  def register_webrtc(session_id, webrtc_url, ice_servers \\ nil) do
    case Repo.get(StreamSession, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        attrs = %{
          webrtc_url: webrtc_url,
          last_activity_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        attrs = if is_nil(ice_servers), do: attrs, else: Map.put(attrs, :webrtc_ice_servers, ice_servers)

        {:ok,
         session
         |> Ecto.Changeset.change(attrs)
         |> Repo.update!()}
    end
  end

  # Marks a session ended; if it was the last live session for its stream, marks
  # the stream offline and enqueues a `stream.stopped` webhook. Returns
  # `{session, stream_stopped?}`.
  defp end_session(session, ended_at) do
    {:ok, session} =
      session
      |> StreamSession.changeset(%{
        status: "ended",
        ended_at: ended_at |> DateTime.truncate(:second)
      })
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

    session = Repo.preload(session, stream: :creator)

    if stream_stopped? do
      :ok =
        Zer0Stream.LifecycleWebhook.enqueue(
          "stream.stopped",
          stream_event_data(session)
        )
    end

    {session, stream_stopped?}
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

  defp stale_after_seconds do
    Application.get_env(:zer0_stream, :stream_stale_after_seconds, 300)
  end
end
