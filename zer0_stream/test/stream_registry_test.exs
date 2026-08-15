defmodule Zer0Stream.StreamRegistryTest do
  use ExUnit.Case

  test "creates and lists a stream" do
    stream =
      Zer0Stream.StreamRegistry.create_stream("stream-1", %{title: "Test Stream", status: "live"})

    assert stream.id == "stream-1"
    assert stream.status == "live"
    assert Enum.any?(Zer0Stream.StreamRegistry.list_streams(), &(&1.id == "stream-1"))
  end
end
