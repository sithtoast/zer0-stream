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
end
