defmodule Zer0Stream.StreamsTest do
  use ExUnit.Case, async: true

  alias Zer0Stream.Streams.{Creator, Stream, StreamKey}

  test "hashes ingest keys without retaining the raw token" do
    token = "test-ingest-token"

    assert StreamKey.hash_token(token) ==
             :crypto.hash(:sha256, token)

    refute StreamKey.hash_token(token) == token
  end

  test "requires a creator external id" do
    changeset = Creator.changeset(%Creator{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).external_id
  end

  test "requires a stream title and creator" do
    changeset = Stream.changeset(%Stream{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).title
    assert "can't be blank" in errors_on(changeset).creator_id
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
