defmodule Zer0Media.HLSRouter do
  @moduledoc """
  Serves HLS playlists, init segments, and media segments over HTTP.

  Files are served straight from the configured `:hls_dir` (default
  `priv/hls`), the same directory `Zer0Media.HLSPipeline` writes to.
  """

  use Plug.Router

  plug(:match)
  plug(:fetch_query_params)
  plug(:dispatch)

  @content_types %{
    ".m3u8" => "application/vnd.apple.mpegurl",
    ".mp4" => "video/mp4",
    ".m4s" => "video/iso.segment",
    ".vtt" => "text/vtt"
  }

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"ok":true,"service":"zer0-media","status":"healthy"}))
  end

  get "/api/sessions/:id/viewers" do
    if control_plane_request_authorized?(conn) do
      %{
        viewer_count: viewer_count,
        updated_at: updated_at,
        average_viewer_count_15m: average_viewer_count_15m
      } = Zer0Media.ViewerTracker.count(id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{
        session_id: session_id_value(id),
        viewer_count: viewer_count,
        average_viewer_count_15m: average_viewer_count_15m,
        updated_at: DateTime.to_iso8601(updated_at)
      }))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"error":"unauthorized"}))
    end
  end

  get "/hls/*path" do
    serve_file(conn, path, hls_dir(), true)
  end

  get "/hls-boombox/*path" do
    serve_file(conn, path, boombox_hls_dir(), true)
  end

  # WebRTC signaling WebSocket, served on the shared origin (same port as HLS)
  # so it is reachable through the existing `stream.dev.zer0.tv` reverse proxy.
  get "/webrtc/:session_id" do
  	case Zer0Media.WebRTCSignalingRegistry.lookup(session_id) do
  		nil ->
  			send_resp(conn, 404, "not found")

  		signaling ->
  			WebSockAdapter.upgrade(
  				conn,
  				Zer0Media.WebRTCSignalingWebSock,
  				%{signaling: signaling},
  				[]
  			)
  	end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp serve_file(conn, path_segments, root_dir, protected?) do
    conn = put_cors_headers(conn)
    base = Path.expand(root_dir)
    requested = Path.join([base | path_segments]) |> Path.expand()
    session_id = stream_session_id(path_segments)

    cond do
      not String.starts_with?(requested, base <> "/") ->
        send_resp(conn, 403, "forbidden")

      not File.regular?(requested) ->
        send_resp(conn, 404, "not found")

      protected? and not Zer0Media.PlaybackToken.valid?(conn.query_params["token"], session_id) ->
        send_resp(conn, 401, "unauthorized")

      protected? and Path.extname(requested) == ".m3u8" ->
        {viewer_id, conn} = viewer_id(conn)

        body =
          requested
          |> File.read!()
          |> normalize_boombox_playlist(conn.query_params["token"])
          |> append_viewer_id(viewer_id)

        conn
        |> track_viewer(session_id, viewer_id)
        |> put_resp_content_type(content_type(requested))
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      Path.extname(requested) == ".m3u8" ->
        {viewer_id, conn} = viewer_id(conn)
        body = requested |> File.read!() |> append_viewer_id(viewer_id)

        conn
        |> track_viewer(session_id, viewer_id)
        |> put_resp_content_type(content_type(requested))
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      true ->
        {viewer_id, conn} = viewer_id(conn)

        conn
        |> track_viewer(session_id, viewer_id)
        |> put_resp_content_type(content_type(requested))
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, requested)
    end
  end

  defp put_cors_headers(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin in allowed_origins() do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("vary", "Origin")
        else
          conn
        end

      _ ->
        conn
    end
  end

  defp allowed_origins do
    Application.get_env(:zer0_media, :hls_allowed_origins) ||
      System.get_env("HLS_ALLOWED_ORIGINS", "http://localhost:3000,http://localhost:4000")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
  end

  defp content_type(path) do
    Map.get(@content_types, Path.extname(path), "application/octet-stream")
  end

  defp normalize_boombox_playlist(body, token) do
    body
    |> String.replace(~r/CODECS=",mp4a\.40\.2"/, ~s(CODECS="avc1.64001f,mp4a.40.2"))
    |> String.split("\n")
    |> Enum.map(&append_playlist_token(&1, token))
    |> Enum.join("\n")
  end

  defp append_playlist_token(line, token) do
    cond do
      String.starts_with?(line, "#EXT-X-MAP:URI=\"") ->
        Regex.replace(~r/URI="([^"]+)"/, line, "URI=\"\\1?token=#{token}\"")

      line == "" or String.starts_with?(line, "#") ->
        line

      true ->
        "#{line}?token=#{token}"
    end
  end

  defp append_viewer_id(body, viewer_id) do
    body
    |> String.split("\n")
    |> Enum.map(&append_viewer_id_to_line(&1, viewer_id))
    |> Enum.join("\n")
  end

  defp append_viewer_id_to_line(line, viewer_id) do
    cond do
      String.starts_with?(line, "#EXT-X-MAP:URI=\"") ->
        Regex.replace(~r/URI="([^"]+)"/, line, fn _, url ->
          "URI=\"#{append_query_param(url, "viewer_id", viewer_id)}\""
        end)

      line == "" or String.starts_with?(line, "#") ->
        line

      true ->
        append_query_param(line, "viewer_id", viewer_id)
    end
  end

  defp append_query_param(url, key, value) do
    uri = URI.parse(url)
    query = uri.query |> to_string() |> URI.decode_query() |> Map.put(key, value) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp control_plane_request_authorized?(conn) do
    Zer0Media.ControlPlaneAuth.valid?(
      conn.method,
      conn.request_path,
      %{},
      get_req_header(conn, "x-zer0-timestamp") |> List.first(),
      get_req_header(conn, "x-zer0-signature") |> List.first()
    )
  end

  defp track_viewer(conn, nil, _viewer_id), do: conn

  defp track_viewer(conn, session_id, viewer_id) do
    :ok = Zer0Media.ViewerTracker.heartbeat(session_id, viewer_id)
    conn
  end

  defp viewer_id(conn) do
    conn = fetch_cookies(conn)

    case conn.query_params["viewer_id"] || conn.cookies["zer0_viewer_id"] do
      viewer_id when is_binary(viewer_id) and byte_size(viewer_id) in 1..128 ->
        {viewer_id, conn}

      _ ->
        viewer_id = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

        {viewer_id,
         put_resp_cookie(conn, "zer0_viewer_id", viewer_id,
           http_only: true,
           same_site: "Lax",
           max_age: viewer_cookie_max_age()
         )}
    end
  end

  defp viewer_cookie_max_age, do: Application.get_env(:zer0_media, :viewer_cookie_max_age, 86_400)

  defp stream_session_id(["stream-session-" <> session_id | _]) do
    session_id
  end

  defp stream_session_id(_path_segments), do: nil

  defp session_id_value(id) do
    case Integer.parse(id) do
      {stream_id, ""} -> stream_id
      :error -> id
    end
  end

  defp hls_dir do
    Application.get_env(:zer0_media, :hls_dir, "priv/hls")
  end

  defp boombox_hls_dir, do: Path.join(File.cwd!(), "priv/hls-boombox")
end
