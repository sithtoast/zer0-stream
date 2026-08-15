defmodule Zer0Media.RTMPServer do
  alias Zer0Media.{ControlPlane, HLSPipeline, RTMPClientHandler, RTMPRelayPipeline}

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

        unless boombox_mode?() do
          {:ok, _hls_supervisor, _hls_pipeline} =
            Membrane.Pipeline.start_link(HLSPipeline,
              client_ref: client_ref,
              output_dir: hls_output_dir(session_id),
              parent: self()
            )
        end

        boombox_pid = maybe_start_relay(client_ref, session_id)

        {RTMPClientHandler,
         %{client_ref: client_ref, connection_id: connection_id, boombox_pid: boombox_pid}}

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
