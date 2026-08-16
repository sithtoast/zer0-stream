defmodule Zer0Stream.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Zer0Stream.Repo,
      Zer0StreamWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:zer0_stream, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Zer0Stream.PubSub},
      {Task.Supervisor, name: Zer0Stream.WebhookTaskSupervisor},
      # Start a worker by calling: Zer0Stream.Worker.start_link(arg)
      # {Zer0Stream.Worker, arg},
      # Start to serve requests, typically the last entry
      Zer0StreamWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Zer0Stream.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Zer0StreamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
