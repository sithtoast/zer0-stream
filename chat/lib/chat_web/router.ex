defmodule ChatWeb.Router do
  use ChatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  get "/health", ChatWeb.HealthController, :show

  scope "/api", ChatWeb do
    pipe_through :api
  end
end
