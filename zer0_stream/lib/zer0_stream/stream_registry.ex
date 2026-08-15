defmodule Zer0Stream.StreamRegistry do
  use GenServer

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    {:ok, %{streams: %{}}}
  end

  def list_streams do
    GenServer.call(__MODULE__, :list_streams)
  end

  def create_stream(stream_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_stream, stream_id, attrs})
  end

  def handle_call(:list_streams, _from, state) do
    {:reply, Map.values(state.streams), state}
  end

  def handle_call({:create_stream, stream_id, attrs}, _from, state) do
    stream =
      %{
        id: stream_id,
        title: Map.get(attrs, :title, "untitled stream"),
        status: Map.get(attrs, :status, "offline"),
        creator_id: Map.get(attrs, :creator_id, "unknown"),
        started_at: Map.get(attrs, :started_at),
        updated_at: DateTime.utc_now()
      }

    {:reply, stream, %{state | streams: Map.put(state.streams, stream_id, stream)}}
  end
end
