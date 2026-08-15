defmodule Zer0StreamWeb.StreamController do
  use Zer0StreamWeb, :controller

  alias Zer0Stream.Streams

  def health(conn, _params) do
    json(conn, %{
      ok: true,
      service: "zer0-stream",
      status: "healthy",
      timestamp: DateTime.utc_now()
    })
  end

  def index(conn, _params) do
    streams = Streams.list_streams()
    json(conn, %{streams: Enum.map(streams, &stream_json/1)})
  end

  def create_creator(conn, params) do
    case Streams.create_creator(%{
           external_id: Map.get(params, "external_id"),
           display_name: Map.get(params, "display_name")
         }) do
      {:ok, creator} -> json(conn, %{creator: creator_json(creator)})
      {:error, changeset} -> validation_error(conn, changeset)
    end
  end

  def create_persistent(conn, %{"creator_id" => creator_id, "title" => title}) do
    case Streams.create_stream(%{creator_id: creator_id, title: title}) do
      {:ok, stream} ->
        conn
        |> put_status(:created)
        |> json(%{stream: stream_json(stream)})

      {:error, changeset} ->
        validation_error(conn, changeset)
    end
  end

  def create_persistent(conn, _params),
    do: json(conn, %{error: "creator_id and title are required"})

  def rotate_key(conn, %{"id" => id}) do
    case Streams.get_stream(id) do
      nil ->
        send_resp(conn, :not_found, "")

      stream ->
        case Streams.rotate_stream_key(stream) do
          {:ok, %{key: key, token: token}} -> json(conn, %{stream_key: key_json(key, token)})
          {:error, changeset} -> validation_error(conn, changeset)
        end
    end
  end

  defp validation_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    })
  end

  defp creator_json(creator),
    do: %{id: creator.id, external_id: creator.external_id, display_name: creator.display_name}

  defp stream_json(stream) do
    %{id: stream.id, creator_id: stream.creator_id, title: stream.title, status: stream.status}
  end

  defp key_json(key, token), do: %{id: key.id, stream_id: key.stream_id, token: token}
end
