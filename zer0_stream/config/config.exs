# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :zer0_stream,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Zer0Stream.Repo],
  # How often the SessionReconciler sweeps for stale live sessions (ms).
  session_reconcile_interval_ms: 60_000,
  # A live session is considered stale after this many seconds without activity.
  stream_stale_after_seconds: 300

# Configures the endpoint
config :zer0_stream, Zer0StreamWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Zer0StreamWeb.ErrorHTML, json: Zer0StreamWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Zer0Stream.PubSub,
  live_view: [signing_salt: "QAWnQ7p1"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
