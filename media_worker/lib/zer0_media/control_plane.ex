defmodule Zer0Media.ControlPlane do
  def authorize(stream_key, connection_id) do
    request(:post, "/api/ingest/rtmp/authorize", %{
      stream_key: stream_key,
      connection_id: connection_id
    })
  end

  def stop(connection_id) do
    request(:post, "/api/ingest/rtmp/#{URI.encode_www_form(connection_id)}/stop", %{})
  end

  defp request(method, path, payload) do
    url = Application.get_env(:zer0_media, :control_plane_url, "http://localhost:4000") <> path

    case Req.request(method: method, url: url, json: payload, receive_timeout: 5_000) do
      {:ok, %{status: 201, body: %{"session" => session}}} -> {:ok, session}
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status}} -> {:error, {:control_plane, status}}
      {:error, reason} -> {:error, {:control_plane, reason}}
    end
  end
end
