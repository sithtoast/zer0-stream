import Config

if System.get_env("PHX_SERVER") do
  config :chat, ChatWeb.Endpoint, server: true
end

config :chat, ChatWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4100"))]

config :chat, :chat_token_secret, System.get_env("CHAT_TOKEN_SECRET", "dev-chat-token-secret")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  chat_token_secret =
    System.get_env("CHAT_TOKEN_SECRET") ||
      raise "environment variable CHAT_TOKEN_SECRET is missing"

  config :chat, Chat.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :chat, :chat_token_secret, chat_token_secret
  config :chat, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :chat, ChatWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "example.com"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    # Origins allowed to open WebSocket connections (comma-separated env).
    check_origin:
      System.get_env("CHAT_ALLOWED_ORIGINS", "http://localhost:4000")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end
