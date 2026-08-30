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

  pipeline :main_app_auth do
    plug Zer0StreamWeb.Plugs.ServiceAuth, role: :main
  end

  pipeline :worker_auth do
    plug Zer0StreamWeb.Plugs.ServiceAuth, role: :worker
  end

  scope "/api", Zer0StreamWeb do
    pipe_through :api

    get "/health", StreamController, :health
    get "/ready", StreamController, :ready
    get "/streams", StreamController, :index
  end

  scope "/api/streams", Zer0StreamWeb do
    pipe_through [:api, :main_app_auth]

    get "/:id/playback", StreamController, :playback
    get "/:id/viewers", StreamController, :viewers
    get "/:id/viewer-metrics", StreamController, :viewer_metrics
    get "/:id/updates", StreamController, :updates
  end

  scope "/api/control", Zer0StreamWeb do
    pipe_through [:api, :main_app_auth]

    post "/creators", StreamController, :create_creator
    post "/creators/:id/keys", StreamController, :rotate_creator_key
    post "/streams", StreamController, :create_persistent
    patch "/streams/:id", StreamController, :update_stream
  end

  scope "/api/ingest", Zer0StreamWeb do
    pipe_through [:api, :worker_auth]

    post "/rtmp/authorize", IngestController, :authorize
    post "/rtmp/:connection_id/stop", IngestController, :stop
    post "/rtmp/reconcile", IngestController, :reconcile
    post "/sessions/:session_id/viewer-samples", IngestController, :viewer_sample
    post "/sessions/:session_id/heartbeat", IngestController, :heartbeat
    put "/sessions/:session_id/webrtc", IngestController, :register_webrtc
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
