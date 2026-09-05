defmodule Zer0Media.TURNTest do
  use ExUnit.Case
  alias Zer0Media.TURN

  setup do
    keys = ["TURN_SECRET", "TURN_URL", "TURN_PUBLIC_URL"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("TURN_SECRET", "test-secret")
    System.put_env("TURN_URL", "turn:192.0.2.1:3478")
    System.put_env("TURN_PUBLIC_URL", "turn:example.test:3478")

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)
  end

  test "viewers and worker connections have independent quota identities" do
    [_, a] = TURN.browser_ice_servers("viewer-a")
    [_, retry] = TURN.browser_ice_servers("viewer-a")
    [_, b] = TURN.browser_ice_servers("viewer-b")
    [_, worker] = TURN.ice_servers("viewer-a")
    identity = fn server -> server.username |> String.split(":", parts: 2) |> List.last() end
    assert identity.(a) == identity.(retry)
    assert length(Enum.uniq(Enum.map([a, b, worker], identity))) == 3

    for server <- [a, b, worker] do
      assert server.credential ==
               Base.encode64(:crypto.mac(:hmac, :sha, "test-secret", server.username))

      [expires, _] = String.split(server.username, ":", parts: 2)
      assert String.to_integer(expires) > System.system_time(:second)
    end
  end
end
