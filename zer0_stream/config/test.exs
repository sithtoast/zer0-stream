import Config

config :zer0_stream, Zer0Stream.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "zer0_stream_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :zer0_stream, Zer0StreamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "EpYxNlLkKXb5acxn8pl/5f8cleJ6yAh/vLkQUnoGPaQAL1+/pBwPY+/zS+etirfx",
  server: false

config :zer0_stream, :service_auth_secret, "test-service-auth-secret"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
