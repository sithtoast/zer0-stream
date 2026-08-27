defmodule Zer0StreamWeb.StreamController do
  use Zer0StreamWeb, :controller

  alias Zer0Stream.{Streams, Viewers}

  def health(conn, _params) do
    json(conn, %{
      ok: true,
      service: "zer0-stream",
      status: "healthy",
      timestamp: DateTime.utc_now()
    })
  end

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Zer0Stream.Repo, "SELECT 1") do
      {:ok, _result} ->
        json(conn, %{ok: true, service: "zer0-stream", status: "ready"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{ok: false, service: "zer0-stream", status: "unavailable"})
    end
  end

  def index(conn, _params) do
    streams = Streams.list_streams()
    json(conn, %{streams: Enum.map(streams, &stream_json/1)})
  end

  def playback(conn, %{"id" => id}) do
    case Streams.get_live_session(id) do
      nil ->
        send_resp(conn, :not_found, "")

      session ->
        base_url = Application.get_env(:zer0_stream, :playback_base_url, "http://localhost:8080")
        token = Zer0Stream.PlaybackToken.issue(session.id)

        playlist =
          "#{base_url}/hls-boombox/stream-session-#{session.id}/master.m3u8?token=#{token}"

        resp = %{
          stream_id: session.stream_id,
          session_id: session.id,
          playback_url: playlist,
          playback_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        }

        resp =
          if session.webrtc_url do
            Map.put(resp, :webrtc_url, session.webrtc_url)
          else
            resp
          end

        json(conn, resp)
    end
  end

  def viewers(conn, %{"id" => id}) do
    case Streams.get_stream(id) do
      nil ->
        send_resp(conn, :not_found, "")

      stream ->
        case Streams.get_live_session(stream.id) do
          nil ->
            json(conn, %{stream_id: stream.id, viewer_count: 0, live: false})

          session ->
            case Zer0Stream.MediaWorker.viewer_snapshot(session.id) do
              {:ok, snapshot} ->
                json(conn, Map.merge(snapshot, %{stream_id: stream.id, live: true}))

              {:error, _reason} ->
                conn
                |> put_status(:service_unavailable)
                |> json(%{error: "viewer count unavailable"})
            end
        end
    end
  end

  def viewer_metrics(conn, %{"id" => id} = params) do
    limit = params |> Map.get("limit", "100") |> parse_limit()

    case Streams.get_stream(id) do
      nil ->
        send_resp(conn, :not_found, "")

      stream ->
        %{samples: samples, average_viewer_count: average_viewer_count} =
          Viewers.historical_series(stream.id, limit)

        json(conn, %{
          stream_id: stream.id,
          average_viewer_count: average_viewer_count,
          samples: Enum.map(samples, &viewer_sample_json/1)
        })
    end
  end

  def create_creator(conn, params) do
    case Streams.create_creator(%{
           external_id: Map.get(params, "external_id"),
           display_name: Map.get(params, "display_name")
         }) do
      {:ok, creator} -> json(conn, %{creator: creator_json(creator)})
      {:ok, creator, :existing} -> json(conn, %{creator: creator_json(creator)})
      {:error, changeset} -> validation_error(conn, changeset)
    end
  end

  def create_persistent(conn, %{
        "creator_id" => creator_id,
        "title" => title,
        "request_id" => request_id
      } = params) do
    attrs = %{
      creator_id: creator_id,
      title: title,
      category_name: Map.get(params, "category_name"),
      category_twitch_id: Map.get(params, "category_twitch_id")
    }

    case Streams.create_stream_once(attrs, request_id) do
      {:ok, {:created, stream}} ->
        conn
        |> put_status(:created)
        |> json(%{stream: stream_json(stream)})

      {:ok, {:existing, stream}} ->
        json(conn, %{stream: stream_json(stream)})

      {:error, :missing_request_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "request_id is required"})

      {:error, changeset} ->
        validation_error(conn, changeset)
    end
  end

  def create_persistent(conn, _params),
    do: json(conn, %{error: "creator_id, title, and request_id are required"})

  def update_stream(conn, %{"id" => id} = params) do
    case Streams.get_stream(id) do
      nil ->
        send_resp(conn, :not_found, "")

      stream ->
        case Streams.update_stream(stream, Map.take(params, ["title", "category_name", "category_twitch_id"])) do
          {:ok, stream} -> json(conn, %{stream: stream_json(stream)})
          {:error, changeset} -> validation_error(conn, changeset)
        end
    end
  end

  def update_stream(conn, _params), do: json(conn, %{error: "title or category is required"})

  def rotate_creator_key(conn, %{"id" => id}) do
    case Streams.get_creator(id) do
      nil ->
        send_resp(conn, :not_found, "")

      creator ->
        case Streams.rotate_creator_stream_key(creator) do
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
    %{
      id: stream.id,
      creator_id: stream.creator_id,
      title: stream.title,
      category_name: stream.category_name,
      category_twitch_id: stream.category_twitch_id,
      status: stream.status
    }
  end

  defp key_json(key, token), do: %{id: key.id, creator_id: key.creator_id, token: token}

  defp viewer_sample_json(sample) do
    %{
      viewer_count: sample.viewer_count,
      sampled_at: sample.sampled_at,
      stream_session_id: sample.stream_session_id
    }
  end

  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _ -> 100
    end
  end
end
