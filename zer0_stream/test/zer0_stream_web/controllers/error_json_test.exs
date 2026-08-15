defmodule Zer0StreamWeb.ErrorJSONTest do
  use Zer0StreamWeb.ConnCase, async: true

  test "renders 404" do
    assert Zer0StreamWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert Zer0StreamWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
