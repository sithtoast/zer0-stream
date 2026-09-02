defmodule Zer0Media.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Logger.configure(level: log_level())

    children = [
      Zer0Media.BoomboxSessionSupervisor,
      Zer0Media.LivePipelineSupervisor,
      Zer0Media.HLSCleanup,
      Zer0Media.ViewerTracker,
      Zer0Media.ViewerMetricsReporter,
      Zer0Media.SessionTracker,
      Zer0Media.SessionHeartbeatReporter,
      Zer0Media.WebRTCSignalingRegistry,
      {Bandit, plug: Zer0Media.HLSRouter, port: http_port(), scheme: :http}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Zer0Media.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Membrane's default :debug logging is extremely verbose (full pipeline spec
  # dumps per stream); default to :info unless LOG_LEVEL overrides it.
  defp log_level do
    case System.get_env("LOG_LEVEL") do
      nil -> :info
      level -> String.to_atom(level)
    end
  end

  defp http_port do
    value = Application.get_env(:zer0_media, :hls_http_port) || System.get_env("HLS_HTTP_PORT")

    case value do
      nil -> 8080
      value when is_integer(value) -> value
      value -> String.to_integer(value)
    end
  end
end
