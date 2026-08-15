defmodule Zer0Stream.Repo do
  use Ecto.Repo,
    otp_app: :zer0_stream,
    adapter: Ecto.Adapters.Postgres
end
