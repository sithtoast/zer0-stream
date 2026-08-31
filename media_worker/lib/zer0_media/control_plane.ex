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

  def reconcile do
    request(:post, "/api/ingest/rtmp/reconcile", %{})
  end

  def report_webrtc(session_id, webrtc_url) do
    request(:put, "/api/ingest/sessions/#{session_id}/webrtc", %{
      session_id: session_id,
      webrtc_url: webrtc_url
    })
  end

  def record_viewer_sample(session_id, viewer_count) do
    request(:post, "/api/ingest/sessions/#{session_id}/viewer-samples", %{
      viewer_count: viewer_count
    })
  end

  def heartbeat(session_id) do
    request(:post, "/api/ingest/sessions/#{session_id}/heartbeat", %{})
  end

  defp request(method, path, payload) do
    url = control_plane_url() <> path
    {timestamp, signature} = Zer0Media.ControlPlaneAuth.sign(method, path, payload)

    case Req.request(
           method: method,
           url: url,
           json: payload,
           headers: [{"x-zer0-timestamp", timestamp}, {"x-zer0-signature", signature}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 201, body: %{"session" => session}}} -> {:ok, session}
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status}} -> {:error, {:control_plane, status}}
      {:error, reason} -> {:error, {:control_plane, reason}}
    end
  end

  # Prefer the app config (set via CLI/dev task), otherwise read the
  # CONTROL_PLANE_URL env var, falling back to the local default.
  defp control_plane_url do
    Application.get_env(:zer0_media, :control_plane_url) ||
      System.get_env("CONTROL_PLANE_URL", "http://localhost:4000")
  end
end
