defmodule Zer0Media.WebRTCSignalingRegistryTest do
  use ExUnit.Case, async: true
  alias Zer0Media.WebRTCSignalingRegistry, as: Registry

  test "a replaced pipeline's exit cannot remove the replacement" do
    id = "registry-#{System.unique_integer([:positive])}"

    old =
      start_supervised!(%{
        id: :old,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :stop -> :ok
               end
             end
           ]},
        restart: :temporary
      })

    new =
      start_supervised!(%{
        id: :new,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :stop -> :ok
               end
             end
           ]},
        restart: :temporary
      })

    Registry.register(id, old)
    Registry.register(id, new)
    ref = Process.monitor(old)
    send(old, :stop)
    assert_receive {:DOWN, ^ref, :process, ^old, :normal}
    assert Registry.lookup(id) == new
    ref = Process.monitor(new)
    send(new, :stop)
    assert_receive {:DOWN, ^ref, :process, ^new, :normal}
    assert Registry.lookup(id) == nil
  end
end
