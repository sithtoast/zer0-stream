defmodule Zer0StreamWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Zer0StreamWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      # The default endpoint for testing
      @endpoint Zer0StreamWeb.Endpoint

      use Zer0StreamWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Zer0StreamWeb.ConnCase
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Zer0Stream.Repo)

    unless tags[:async] do
      Sandbox.mode(Zer0Stream.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def service_conn(conn, method, path, params) do
    {timestamp, signature} = Zer0Stream.ServiceAuth.sign(method, path, params)

    conn
    |> Plug.Conn.put_req_header("x-zer0-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-zer0-signature", signature)
  end
end
