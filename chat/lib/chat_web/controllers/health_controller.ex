defmodule ChatWeb.HealthController do
  use ChatWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "chat"})
  end
end
