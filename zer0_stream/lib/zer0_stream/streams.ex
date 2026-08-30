defmodule Zer0Stream.Streams do
  import Ecto.Query, only: [from: 2]

  alias Zer0Stream.Repo
  alias Zer0Stream.{IdempotencyRecord, Repo}
  alias Zer0Stream.Streams.{Creator, Stream, StreamKey, StreamSession, StreamUpdate}

  def create_creator(attrs) do
    case Map.get(attrs, :external_id) do
      nil ->
        %Creator{}
        |> Creator.changeset(attrs)
        |> Repo.insert()

      external_id ->
        case Repo.get_by(Creator, external_id: external_id) do
          nil ->
            %Creator{}
            |> Creator.changeset(attrs)
            |> Repo.insert()

          creator ->
            {:ok, creator, :existing}
        end
    end
  end

  def get_creator(id), do: Repo.get(Creator, id)
  def get_creator!(id), do: Repo.get!(Creator, id)

  def create_stream(attrs) do
    %Stream{}
    |> Stream.changeset(attrs)
    |> Repo.insert()
  end

  def create_stream_once(attrs, request_id)
      when is_binary(request_id) and byte_size(request_id) > 0 do
    result =
      Repo.transaction(fn ->
        case Repo.get_by(IdempotencyRecord, operation: "create_stream", request_id: request_id) do
          %IdempotencyRecord{resource_id: stream_id} ->
            {:existing, Repo.get!(Stream, stream_id)}

          nil ->
            with {:ok, stream} <- create_stream(attrs),
                 {:ok, _record} <-
                   %IdempotencyRecord{}
                   |> IdempotencyRecord.changeset(%{
                     operation: "create_stream",
                     request_id: request_id,
                     resource_id: stream.id
                   })
                   |> Repo.insert() do
              {:created, stream}
            else
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:error, changeset} ->
        case Repo.get_by(IdempotencyRecord, operation: "create_stream", request_id: request_id) do
          %IdempotencyRecord{resource_id: stream_id} ->
            {:ok, {:existing, Repo.get!(Stream, stream_id)}}

          nil ->
            {:error, changeset}
        end

      result ->
        result
    end
  end

  def create_stream_once(_attrs, _request_id), do: {:error, :missing_request_id}

  def get_stream(id), do: Repo.get(Stream, id)

  def update_stream(%Stream{} = stream, attrs) do
    stream
    |> Stream.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a stream's title/category and, when a live session exists, records the
  change in `stream_updates` and emits a `stream.updated` lifecycle webhook.
  Returns `{:ok, stream}` / `{:error, changeset}`.
  """
  def update_stream_with_history(%Stream{} = stream, attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated} <- update_stream(stream, attrs) do
          record_stream_update(updated)
          {:ok, updated}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, {:ok, updated}} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp record_stream_update(%Stream{} = stream) do
    session = get_live_session(stream.id)

    %StreamUpdate{}
    |> StreamUpdate.changeset(%{
      stream_id: stream.id,
      session_id: session && session.id,
      title: stream.title,
      category_name: stream.category_name,
      category_twitch_id: stream.category_twitch_id,
      changed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    :ok =
      Zer0Stream.LifecycleWebhook.enqueue(
        "stream.updated",
        stream_update_event_data(stream, session)
      )

    :ok
  end

  defp stream_update_event_data(stream, session) do
    %{
      stream: %{
        id: stream.id,
        creator_id: stream.creator_id,
        title: stream.title,
        category_name: stream.category_name,
        category_twitch_id: stream.category_twitch_id,
        status: stream.status
      },
      session:
        session &&
          %{
            id: session.id,
            connection_id: session.connection_id,
            protocol: session.protocol,
            status: session.status,
            started_at: session.started_at,
            ended_at: session.ended_at
          }
    }
  end

  def get_stream_for_creator(creator_id), do: Repo.get_by(Stream, creator_id: creator_id)

  def list_streams do
    Repo.all(from(stream in Stream, preload: [:creator]))
  end

  def get_live_session(stream_id) do
    Repo.one(
      from(session in StreamSession,
        where: session.stream_id == ^stream_id and session.status == "live",
        order_by: [desc: session.started_at],
        limit: 1,
        preload: [stream: :creator]
      )
    )
  end

  def list_stream_updates(stream_id, limit \\ 50) do
    Repo.all(
      from(update in StreamUpdate,
        where: update.stream_id == ^stream_id,
        order_by: [desc: update.changed_at],
        limit: ^normalize_limit(limit),
        preload: [:session]
      )
    )
  end

  defp normalize_limit(limit) when is_integer(limit), do: min(max(limit, 1), 1_000)
  defp normalize_limit(_limit), do: 50

  def rotate_creator_stream_key(%Creator{id: creator_id}) do
    token = generate_token()

    Repo.transaction(fn ->
      Repo.update_all(
        from(key in StreamKey, where: key.creator_id == ^creator_id and is_nil(key.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )

      {:ok, key} =
        %StreamKey{}
        |> StreamKey.changeset(%{creator_id: creator_id, token_hash: StreamKey.hash_token(token)})
        |> Repo.insert()

      %{key: key, token: token}
    end)
  end

  def authenticate_stream_key(token) when is_binary(token) do
    token_hash = StreamKey.hash_token(token)

    Repo.one(
      from(key in StreamKey,
        where: key.token_hash == ^token_hash and is_nil(key.revoked_at),
        preload: [:creator]
      )
    )
  end

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
