alias Zer0Stream.Streams
alias Zer0Stream.Repo
alias Zer0Stream.Streams.{Creator, Stream}

creator =
  Repo.get_by(Creator, external_id: "local-dev") ||
    case Streams.create_creator(%{external_id: "local-dev", display_name: "Local Developer"}) do
      {:ok, creator} -> creator
      {:error, changeset} -> raise "could not create local creator: #{inspect(changeset.errors)}"
    end

stream =
  Repo.get_by(Stream, creator_id: creator.id, title: "Local Test Stream") ||
    case Streams.create_stream(%{creator_id: creator.id, title: "Local Test Stream"}) do
      {:ok, stream} -> stream
      {:error, changeset} -> raise "could not create local stream: #{inspect(changeset.errors)}"
    end

{:ok, %{token: token}} = Streams.rotate_stream_key(stream)

IO.puts("Created local stream #{stream.id}")
IO.puts("Ingest key: #{token}")
