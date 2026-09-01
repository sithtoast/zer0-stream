defmodule Zer0Media.RTMPServer do
  alias Zer0Media.{ControlPlane, RTMPClientHandler, RTMPRelayPipeline}

  require Logger

  def start_link(opts \\ []) do
    ControlPlane.reconcile()

    if boombox_mode?(), do: Zer0Media.BoomboxSession.prewarm()

    Membrane.RTMPServer.start_link(
      port: Keyword.get(opts, :port, Application.get_env(:zer0_media, :rtmp_port, 1935)),
      client_timeout: Membrane.Time.seconds(15),
      handle_new_client: &handle_new_client/3,
      name: Keyword.get(opts, :name, Zer0Media.RTMPServer)
    )
  end

  def handle_new_client(client_ref, _app, stream_key) do
    connection_id = connection_id()
    Logger.info("Incoming RTMP connection #{connection_id} stream_key=#{stream_key}")

    case ControlPlane.authorize(stream_key, connection_id) do
      {:ok, session} ->
        session_id = session["id"] || session[:id]
        Logger.info("Authorized RTMP session #{session_id} (#{connection_id})")

        if live_pipeline_mode?() do
          {live_pipeline_pid, webrtc_port} = start_live_pipeline(client_ref, session_id)

          {RTMPClientHandler,
           %{
             client_ref: client_ref,
             connection_id: connection_id,
             session_id: session_id,
             boombox_pid: nil,
             live_pipeline_pid: live_pipeline_pid,
             webrtc_port: webrtc_port,
             hls_output_dir: hls_output_dir(session_id)
           }}
        else
          boombox_pid = maybe_start_relay(client_ref, session_id)

          {RTMPClientHandler,
           %{
             client_ref: client_ref,
             connection_id: connection_id,
             session_id: session_id,
             boombox_pid: boombox_pid,
             live_pipeline_pid: nil,
             webrtc_port: nil,
             hls_output_dir: nil
           }}
        end

      {:error, reason} ->
        Logger.error("RTMP authorization failed #{connection_id}: #{inspect(reason)}")
        {Zer0Media.RTMPRejectHandler, %{client_ref: client_ref, reason: reason}}
    end
  end

  defp hls_output_dir(session_id) do
    output_dir = Application.get_env(:zer0_media, :hls_dir, "priv/hls")
    path = Path.join(output_dir, "stream-session-#{session_id}")
    File.mkdir_p!(path)
    path
  end

  defp start_live_pipeline(client_ref, session_id) do
    # Normalize to a string: session_id comes from the control plane as an
    # integer, but it is used as a string in the signaling URL and as the
    # WebRTC signaling registry key (matched against the /webrtc/:session_id
    # route, which is always a string).
    session_id = to_string(session_id)
    output_dir = hls_output_dir(session_id)

    case Membrane.Pipeline.start_link(Zer0Media.LivePipeline,
           client_ref: client_ref,
           output_dir: output_dir,
           session_id: session_id,
           parent: self()
         ) do
      {:ok, _supervisor, pipeline} ->
        signaling_url = signaling_url(session_id)

        Logger.info(
          "Live pipeline session #{session_id} ready; " <>
            "WebRTC signaling at #{signaling_url}"
        )

        ControlPlane.report_webrtc(session_id, signaling_url, Zer0Media.TURN.browser_ice_servers())

        {pipeline, nil}

      {:error, reason} ->
        Logger.error("Unable to start live pipeline: #{inspect(reason)}")
        {nil, nil}
    end
  end

  # The signaling URL reported to the control plane (and served to the browser).
  # WebRTC signaling is served on the shared origin (same port as HLS), so the
  # URL is just the public origin + /webrtc/<session_id>.
  #
  # Defaults to a localhost URL for local testing. For internet-facing deployments
  # set WEBRTC_PUBLIC_URL_TEMPLATE to the public origin (proxied through
  # Caddy/OPNsense to the media worker's HTTP port), with a ":session_id"
  # placeholder, e.g.
  #   wss://stream.dev.zer0.tv/webrtc/:session_id
  defp signaling_url(session_id) do
    session_id = to_string(session_id)

    case System.get_env("WEBRTC_PUBLIC_URL_TEMPLATE") do
      nil -> "ws://localhost:8080/webrtc/#{session_id}"
      template -> String.replace(template, ":session_id", session_id)
    end
  end

  defp live_pipeline_mode? do
    System.get_env("LIVE_PIPELINE_MODE", "false") in ["1", "true"]
  end

  defp maybe_start_relay(client_ref, session_id) do
    case boombox_mode?() do
      false ->
        case relay_url(session_id) do
          nil ->
            nil

          relay_url ->
            start_relay(client_ref, relay_url)
            nil
        end

      true ->
        case Zer0Media.BoomboxSessionSupervisor.start_session(session_id) do
          {:ok, boombox_pid} ->
            Logger.info("Boombox session #{session_id} ready; starting relay")

            case start_relay(client_ref, Zer0Media.BoomboxSession.relay_url(boombox_pid)) do
              :ok -> boombox_pid
              :error -> Zer0Media.BoomboxSessionSupervisor.stop_session(boombox_pid)
            end

          {:error, reason} ->
            Logger.error("Unable to start Boombox session: #{inspect(reason)}")
            nil
        end
    end
  end

  defp start_relay(client_ref, relay_url) do
    case Membrane.Pipeline.start_link(RTMPRelayPipeline,
           client_ref: client_ref,
           relay_url: relay_url,
           parent: self()
         ) do
      {:ok, _supervisor_pid, _pipeline_pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Unable to start Boombox RTMP relay: #{inspect(reason)}")
        :error
    end
  end

  defp boombox_mode? do
    System.get_env("LEGACY_HLS_MODE", "false") not in ["1", "true"]
  end

  defp relay_url(session_id) do
    case System.get_env("BOOMBOX_RELAY_URL") do
      nil ->
        nil

      template ->
        String.replace(template, ":session_id", to_string(session_id))
    end
  end

  defp connection_id do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    "rtmp-#{token}"
  end
end
