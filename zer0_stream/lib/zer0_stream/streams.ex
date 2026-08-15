defmodule Zer0Stream.Streams do
  import Ecto.Query, only: [from: 2]

  alias Zer0Stream.Repo
  alias Zer0Stream.Streams.{Creator, Stream, StreamKey}

  def create_creator(attrs) do
    %Creator{}
    |> Creator.changeset(attrs)
    |> Repo.insert()
  end

  def get_creator!(id), do: Repo.get!(Creator, id)

  def create_stream(attrs) do
    %Stream{}
    |> Stream.changeset(attrs)
    |> Repo.insert()
  end

  def get_stream(id), do: Repo.get(Stream, id)

  def list_streams do
    Repo.all(from(stream in Stream, preload: [:creator]))
  end

  def rotate_stream_key(%Stream{id: stream_id}) do
    token = generate_token()

    Repo.transaction(fn ->
      Repo.update_all(
        from(key in StreamKey, where: key.stream_id == ^stream_id and is_nil(key.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )

      {:ok, key} =
        %StreamKey{}
        |> StreamKey.changeset(%{stream_id: stream_id, token_hash: StreamKey.hash_token(token)})
        |> Repo.insert()

      %{key: key, token: token}
    end)
  end

  def authenticate_stream_key(token) when is_binary(token) do
    token_hash = StreamKey.hash_token(token)

    Repo.one(
      from(key in StreamKey,
        where: key.token_hash == ^token_hash and is_nil(key.revoked_at),
        preload: [stream: :creator]
      )
    )
  end

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
