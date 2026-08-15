defmodule Zer0Media.HLSRouter do
  @moduledoc """
  Serves HLS playlists, init segments, and media segments over HTTP.

  Files are served straight from the configured `:hls_dir` (default
  `priv/hls`), the same directory `Zer0Media.HLSPipeline` writes to.
  """

  use Plug.Router

  plug(:match)
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

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp serve_file(conn, path_segments) do
    conn = put_cors_headers(conn)
    base = hls_dir() |> Path.expand()
    requested = Path.join([base | path_segments]) |> Path.expand()

    cond do
      not String.starts_with?(requested, base <> "/") ->
        send_resp(conn, 403, "forbidden")

      not File.regular?(requested) ->
        send_resp(conn, 404, "not found")

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

  defp hls_dir do
    Application.get_env(:zer0_media, :hls_dir, "priv/hls")
  end
end
