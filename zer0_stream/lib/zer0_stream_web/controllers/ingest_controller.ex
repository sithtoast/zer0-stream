defmodule Zer0StreamWeb.IngestController do
  use Zer0StreamWeb, :controller

  alias Zer0Stream.Ingest.RTMPAdapter

  def authorize(conn, %{"stream_key" => stream_key, "connection_id" => connection_id}) do
    case RTMPAdapter.authorize(%{stream_key: stream_key, connection_id: connection_id}) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{session: session_json(session), stream: stream_json(session.stream)})

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid stream key"})

      {:error, :connection_id_reused} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "connection_id has already ended"})
    end
  end

  def authorize(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "stream_key and connection_id are required"})
  end

  def stop(conn, %{"connection_id" => connection_id}) do
    case RTMPAdapter.disconnect(connection_id) do
      {:ok, session} -> json(conn, %{session: %{id: session.id, status: session.status}})
      {:error, :not_found} -> send_resp(conn, :not_found, "")
    end
  end

  def reconcile(conn, _params) do
    {:ok, ended_count} = Zer0Stream.Ingest.reconcile_sessions()
    json(conn, %{ended_sessions: ended_count})
  end

  def heartbeat(conn, %{"session_id" => session_id}) do
    case Zer0Stream.Ingest.heartbeat(session_id) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> send_resp(conn, :not_found, "")
    end
  end

  def viewer_sample(conn, %{"session_id" => session_id, "viewer_count" => viewer_count}) do
    case Zer0Stream.Viewers.record_sample(session_id, viewer_count) do
      {:ok, sample} ->
        conn
        |> put_status(:created)
        |> json(%{viewer_sample: viewer_sample_json(sample)})

      {:error, :not_found} ->
        send_resp(conn, :not_found, "")

      {:error, :invalid_viewer_count} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "viewer_count must be a non-negative integer"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
        })
    end
  end

  def viewer_sample(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "viewer_count is required"})
  end

  def register_webrtc(conn, %{"session_id" => session_id, "webrtc_url" => webrtc_url}) do
    case Zer0Stream.Ingest.register_webrtc(session_id, webrtc_url) do
      {:ok, _session} -> json(conn, %{ok: true})
      {:error, :not_found} -> send_resp(conn, :not_found, "")
    end
  end

  def register_webrtc(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "session_id and webrtc_url are required"})
  end

  defp session_json(session) do
    %{
      id: session.id,
      connection_id: session.connection_id,
      protocol: session.protocol,
      status: session.status,
      started_at: session.started_at
    }
  end

  defp stream_json(stream) do
    %{id: stream.id, creator_id: stream.creator_id, title: stream.title, status: stream.status}
  end

  defp viewer_sample_json(sample) do
    %{
      id: sample.id,
      stream_id: sample.stream_id,
      stream_session_id: sample.stream_session_id,
      viewer_count: sample.viewer_count,
      sampled_at: sample.sampled_at
    }
  end
end
