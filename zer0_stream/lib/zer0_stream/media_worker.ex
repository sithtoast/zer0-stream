defmodule Zer0Stream.MediaWorker do
  alias Zer0Stream.ServiceAuth

  def viewer_snapshot(session_id) do
    path = "/api/sessions/#{session_id}/viewers"
    {timestamp, signature} = ServiceAuth.sign(:worker, :get, path, %{})

    case :httpc.request(
           :get,
           {String.to_charlist(media_worker_url() <> path),
            request_headers(timestamp, signature)},
           [timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_http_version, 200, _reason}, _headers, body}} ->
        decode_snapshot(body)

      {:ok, {{_http_version, status, _reason}, _headers, _body}} ->
        {:error, {:media_worker, status}}

      {:error, reason} ->
        {:error, {:media_worker, reason}}
    end
  end

  defp decode_snapshot(body) do
    with {:ok, snapshot} <- Jason.decode(body),
         %{
           "session_id" => session_id,
           "viewer_count" => viewer_count,
           "average_viewer_count_15m" => average_viewer_count_15m,
           "updated_at" => updated_at
         } <- snapshot,
         true <- is_integer(viewer_count),
         true <- is_number(average_viewer_count_15m) do
      {:ok,
       %{
         session_id: session_id,
         viewer_count: viewer_count,
         average_viewer_count_15m: average_viewer_count_15m,
         updated_at: updated_at
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp request_headers(timestamp, signature) do
    [
      {~c"x-zer0-timestamp", String.to_charlist(timestamp)},
      {~c"x-zer0-signature", String.to_charlist(signature)}
    ]
  end

  defp media_worker_url do
    Application.get_env(:zer0_stream, :media_worker_url, "http://localhost:8080")
  end
end
