defmodule Zer0StreamWeb.Router do
  use Zer0StreamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Zer0StreamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", Zer0StreamWeb do
    pipe_through :api

    get "/health", StreamController, :health
    get "/streams", StreamController, :index
    get "/streams/:id/playback", StreamController, :playback
    post "/control/creators", StreamController, :create_creator
    post "/control/streams", StreamController, :create_persistent
    post "/control/streams/:id/keys", StreamController, :rotate_key
    post "/ingest/rtmp/authorize", IngestController, :authorize
    post "/ingest/rtmp/:connection_id/stop", IngestController, :stop
    post "/ingest/rtmp/reconcile", IngestController, :reconcile
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:zer0_stream, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Zer0StreamWeb.Telemetry
    end
  end
end
