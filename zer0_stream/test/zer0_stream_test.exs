defmodule Zer0StreamTest do
  use ExUnit.Case
  doctest Zer0Stream

  test "application module is available" do
    assert Code.ensure_loaded?(Zer0Stream)
  end
end
