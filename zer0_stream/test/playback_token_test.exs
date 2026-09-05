defmodule Zer0Stream.PlaybackTokenTest do
  use ExUnit.Case, async: true
  alias Zer0Stream.PlaybackToken

  test "same viewer survives token rotation and distinct viewers remain distinct" do
    first = PlaybackToken.issue_for_viewer(42, "alice", 100)
    renewed = PlaybackToken.issue_for_viewer(42, "alice", 200)
    other = PlaybackToken.issue_for_viewer(42, "bob", 100)
    refute first == renewed
    assert PlaybackToken.viewer_id(first, "42") == {:ok, "viewer:alice"}
    assert PlaybackToken.viewer_id(renewed, "42") == {:ok, "viewer:alice"}
    assert PlaybackToken.viewer_id(other, "42") == {:ok, "viewer:bob"}
  end

  test "accepts legacy tokens and rejects expired, tampered, and wrong-stream tokens" do
    assert PlaybackToken.valid?(PlaybackToken.issue(42), "42")
    refute PlaybackToken.valid?(PlaybackToken.issue_for_viewer(42, "alice", -1), "42")
    token = PlaybackToken.issue_for_viewer(42, "alice")
    refute PlaybackToken.valid?(token, "43")

    tampered =
      token
      |> Base.url_decode64!(padding: false)
      |> String.replace("alice", "bob")
      |> Base.url_encode64(padding: false)

    assert PlaybackToken.viewer_id(tampered, "42") == :error
  end
end
