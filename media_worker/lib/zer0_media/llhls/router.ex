defmodule Zer0Media.LLHLS.Router do
  @moduledoc "Authenticated LL-HLS origin. Shared URIs; viewer accounting uses explicit heartbeats."
  use Plug.Router
  alias Zer0Media.LLHLS.{Origin, Stream}
  alias Zer0Media.PlaybackToken

  plug(Plug.Head)
  plug(:cors)
  plug(:match)
  plug(:dispatch)

  options _ do
    send_resp(conn, 204, "")
  end

  post "/:session/session" do
    # Exchange a signed token for a path-scoped cookie. Authorization is still
    # checked on EVERY resource request; this is not a public CDN auth bypass.
    with true <- valid_session?(session),
         {:ok, token, identity} <- credential(conn, session, false),
         pid when is_pid(pid) <- Origin.current(session),
         %{status: :live, master: master, ready?: true} = info when is_binary(master) <-
           current_info(pid) do
      secure? = Application.get_env(:zer0_media, :llhls_cookie_secure, true)
      Zer0Media.ViewerTracker.heartbeat(session, identity)

      conn
      |> put_resp_cookie("zer0_llhls", token,
        path: "/llhls/#{session}/",
        http_only: true,
        secure: secure?,
        same_site: if(secure?, do: "None", else: "Lax")
      )
      |> put_resp_content_type("application/json")
      |> private_response(
        200,
        Jason.encode!(%{
          url: "/llhls/#{session}/#{info.generation}/master.m3u8",
          heartbeat_url: "/llhls/#{session}/heartbeat"
        })
      )
    else
      :error -> private_response(conn, 401, "unauthorized")
      false -> private_response(conn, 404, "not found")
      _ -> private_response(conn, 503, "stream not ready")
    end
  end

  post "/:session/heartbeat" do
    with true <- valid_session?(session),
         {:ok, _token, identity} <- credential(conn, session),
         pid when is_pid(pid) <- Origin.current(session),
         %{status: :live} <- current_info(pid) do
      Zer0Media.ViewerTracker.heartbeat(session, identity)
      private_response(conn, 204, "")
    else
      :error -> private_response(conn, 401, "unauthorized")
      _ -> private_response(conn, 410, "stream ended")
    end
  end

  get "/:session/:generation/master.m3u8" do
    serve(conn, session, generation, :master)
  end

  get "/:session/:generation/:rendition/:resource" do
    serve(conn, session, generation, {rendition, resource})
  end

  match _ do
    private_response(conn, 404, "not found")
  end

  defp serve(conn, session, generation, resource) do
    with true <- valid_session?(session) and Regex.match?(~r/\A[0-9a-f]{24}\z/, generation),
         {:ok, token, _identity} <- credential(conn, session),
         origin when is_pid(origin) <- Origin.lookup({session, generation, :origin}) do
      response = resolve(origin, resource, conn.query_string)
      # A blocked response must not outlive its authorization.
      if PlaybackToken.valid?(token, session),
        do: deliver(conn, response),
        else: private_response(conn, 401, "unauthorized")
    else
      :error -> private_response(conn, 401, "unauthorized")
      _ -> private_response(conn, 404, "not found")
    end
  catch
    :exit, _ -> private_response(conn, 503, "origin unavailable")
  end

  defp resolve(origin, :master, _query) do
    case Origin.info(origin) do
      %{status: status, master: body, ready?: true}
      when status in [:live, :ended] and is_binary(body) ->
        {:playlist, body}

      _ ->
        {:error, :unavailable}
    end
  end

  defp resolve(origin, {rendition, "index.m3u8"}, query) do
    with %{status: status} when status in [:live, :ended] <- Origin.info(origin),
         {:ok, msn, part} <- if(status == :ended, do: {:ok, nil, nil}, else: directives(query)),
         {:ok, stream, _directory} <- Origin.track(origin, rendition),
         {:ok, body} <- Stream.await(stream, msn, part) do
      {:playlist, body}
    else
      %{status: _} -> {:error, :unavailable}
      error -> error
    end
  end

  defp resolve(origin, {rendition, name}, _query) do
    with true <- valid_object?(name),
         {:ok, stream, directory} <- Origin.track(origin, rendition) do
      path = Path.join(directory, name)

      cond do
        File.regular?(path) ->
          {:file, path}

        String.starts_with?(name, "part-") ->
          [_, msn, part] = Regex.run(~r/\Apart-([0-9]+)-([0-9]+)\.m4s\z/, name)

          with {:ok, :available} <-
                 Stream.await_part(stream, String.to_integer(msn), String.to_integer(part)),
               true <- File.regular?(path),
               do: {:file, path},
               else: (
                 false -> {:error, :not_found}
                 error -> error
               )

        true ->
          {:error, :not_found}
      end
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp deliver(conn, {:playlist, body}) do
    conn |> put_resp_content_type("application/vnd.apple.mpegurl") |> private_response(200, body)
  end

  defp deliver(conn, {:file, path}) do
    type = if String.ends_with?(path, ".mp4"), do: "video/mp4", else: "video/iso.segment"

    conn
    |> put_resp_content_type(type)
    |> put_resp_header("cache-control", "private, max-age=3600, immutable")
    |> send_file(200, path)
  rescue
    File.Error -> private_response(conn, 404, "not found")
  end

  defp deliver(conn, {:error, reason})
       when reason in [:invalid_request, :part_without_msn, :too_far_ahead],
       do: private_response(conn, 400, "invalid delivery directive")

  defp deliver(conn, {:error, :not_found}), do: private_response(conn, 404, "not found")
  defp deliver(conn, {:error, _}), do: private_response(conn, 503, "origin unavailable")

  @doc false
  def directives(query) when byte_size(query) <= 2048 do
    pairs =
      URI.query_decoder(query) |> Enum.filter(fn {key, _} -> key in ["_HLS_msn", "_HLS_part"] end)

    map = Map.new(pairs)

    with true <- map_size(map) == length(pairs),
         {:ok, msn} <- number(map["_HLS_msn"]),
         {:ok, part} <- number(map["_HLS_part"]),
         true <- part == nil or msn != nil do
      {:ok, msn, part}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_request}
  end

  def directives(_query), do: {:error, :invalid_request}

  defp number(nil), do: {:ok, nil}

  defp number(value) do
    if byte_size(value) <= 20 and Regex.match?(~r/\A[0-9]+\z/, value) do
      value = String.to_integer(value)
      if value <= 18_446_744_073_709_551_615, do: {:ok, value}, else: :error
    else
      :error
    end
  end

  defp credential(conn, session, allow_cookie? \\ true) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        [] when allow_cookie? -> fetch_cookies(conn).cookies["zer0_llhls"]
        _ -> nil
      end

    with true <- is_binary(token) and byte_size(token) <= 1024,
         {:ok, identity} <- PlaybackToken.viewer_id(token, session),
         do: {:ok, token, identity},
         else: (_ -> :error)
  end

  defp valid_session?(value),
    do: byte_size(value) in 1..20 and Regex.match?(~r/\A[0-9]+\z/, value)

  defp valid_object?("init.mp4"), do: true

  defp valid_object?(value) do
    case Regex.run(~r/\A(?:part-([0-9]{1,20})-([0-9]{1,20})|segment-([0-9]{1,20}))\.m4s\z/, value) do
      nil ->
        false

      [_ | numbers] ->
        numbers
        |> Enum.reject(&(&1 == ""))
        |> Enum.all?(fn value ->
          case number(value) do
            {:ok, n} -> Integer.to_string(n) == value
            _ -> false
          end
        end)
    end
  end

  defp current_info(pid) do
    Origin.info(pid)
  catch
    :exit, _ -> :unavailable
  end

  defp private_response(conn, status, body),
    do: conn |> put_resp_header("cache-control", "private, no-store") |> send_resp(status, body)

  defp cors(conn, _opts) do
    origins =
      Application.get_env(:zer0_media, :hls_allowed_origins) ||
        System.get_env("HLS_ALLOWED_ORIGINS", "http://localhost:3000,http://localhost:4000")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if origin in origins do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("access-control-allow-credentials", "true")
          |> put_resp_header("access-control-allow-methods", "GET, HEAD, POST, OPTIONS")
          |> put_resp_header("access-control-allow-headers", "Authorization, Content-Type")
          |> put_resp_header("vary", "Origin")
        else
          conn |> private_response(403, "origin not allowed") |> halt()
        end

      _ ->
        conn |> private_response(403, "origin not allowed") |> halt()
    end
  end
end
