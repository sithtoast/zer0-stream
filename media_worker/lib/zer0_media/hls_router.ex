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

  get "/hls/*path" do
    serve_file(conn, path)
  end

  get "/hls-boombox/*path" do
    serve_file(conn, path, boombox_hls_dir(), true)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp serve_file(conn, path_segments) do
    serve_file(conn, path_segments, hls_dir(), false)
  end

  defp serve_file(conn, path_segments, root_dir, protected?) do
    conn = put_cors_headers(conn)
    base = Path.expand(root_dir)
    requested = Path.join([base | path_segments]) |> Path.expand()
    session_id = boombox_session_id(path_segments)

    cond do
      not String.starts_with?(requested, base <> "/") ->
        send_resp(conn, 403, "forbidden")

      not File.regular?(requested) ->
        send_resp(conn, 404, "not found")

      protected? and not Zer0Media.PlaybackToken.valid?(conn.query_params["token"], session_id) ->
        send_resp(conn, 401, "unauthorized")

      protected? and Path.extname(requested) == ".m3u8" ->
        body = requested |> File.read!() |> normalize_boombox_playlist(conn.query_params["token"])

        conn
        |> put_resp_content_type(content_type(requested))
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      true ->
        conn
        |> put_resp_content_type(content_type(requested))
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, requested)
    end
  end

  defp put_cors_headers(conn) do
    put_resp_header(conn, "access-control-allow-origin", "*")
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

  defp boombox_session_id(["stream-session-" <> session_id | _]) do
    session_id
  end

  defp boombox_session_id(_path_segments), do: nil

  defp hls_dir do
    Application.get_env(:zer0_media, :hls_dir, "priv/hls")
  end

  defp boombox_hls_dir, do: Path.join(File.cwd!(), "priv/hls-boombox")
end
