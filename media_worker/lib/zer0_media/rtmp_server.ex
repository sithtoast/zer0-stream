defmodule Zer0Media.RTMPServer do
  alias Membrane.RTMP.Source.ClientHandlerImpl
  alias Zer0Media.{ControlPlane, HLSPipeline, RTMPRelayPipeline}

  def start_link(opts \\ []) do
    Membrane.RTMPServer.start_link(
      port: Keyword.get(opts, :port, Application.get_env(:zer0_media, :rtmp_port, 1935)),
      client_timeout: Membrane.Time.seconds(15),
      handle_new_client: &handle_new_client/3,
      name: Keyword.get(opts, :name, Zer0Media.RTMPServer)
    )
  end

  def handle_new_client(client_ref, _app, stream_key) do
    connection_id = inspect(client_ref)

    case ControlPlane.authorize(stream_key, connection_id) do
      {:ok, session} ->
        {:ok, _hls_supervisor, _hls_pipeline} =
          Membrane.Pipeline.start_link(HLSPipeline,
            client_ref: client_ref,
            output_dir: hls_output_dir(session["id"] || session[:id]),
            parent: self()
          )

        maybe_start_relay(client_ref)

        ClientHandlerImpl

      {:error, reason} ->
        {Zer0Media.RTMPRejectHandler, %{client_ref: client_ref, reason: reason}}
    end
  end

  defp hls_output_dir(session_id) do
    output_dir = Application.get_env(:zer0_media, :hls_dir, "priv/hls")
    path = Path.join(output_dir, "stream-session-#{session_id}")
    File.mkdir_p!(path)
    path
  end

  defp maybe_start_relay(client_ref) do
    case System.get_env("BOOMBOX_RELAY_URL") do
      nil ->
        :ok

      relay_url ->
        case Membrane.Pipeline.start_link(RTMPRelayPipeline,
               client_ref: client_ref,
               relay_url: relay_url,
               parent: self()
             ) do
          {:ok, _supervisor_pid, _pipeline_pid} ->
            :ok

          {:error, reason} ->
            require Logger
            Logger.error("Unable to start Boombox RTMP relay: #{inspect(reason)}")
        end
    end
  end
end
