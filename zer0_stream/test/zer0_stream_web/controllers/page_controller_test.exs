defmodule Zer0StreamWeb.PageControllerTest do
  use Zer0StreamWeb.ConnCase

  test "GET / returns not found", %{conn: conn} do
    conn = get(conn, "/")
    assert response(conn, 404) == "Not Found"
  end
end
