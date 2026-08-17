defmodule Zer0Media.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Zer0Media.BoomboxSessionSupervisor,
      Zer0Media.HLSCleanup,
      Zer0Media.ViewerTracker,
      Zer0Media.ViewerMetricsReporter,
      {Bandit, plug: Zer0Media.HLSRouter, port: http_port(), scheme: :http}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Zer0Media.Supervisor]
    Supervisor.start_link(children, opts)
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
