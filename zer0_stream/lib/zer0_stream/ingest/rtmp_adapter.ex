defmodule Zer0Stream.Ingest.RTMPAdapter do
  alias Zer0Stream.Ingest

  def authorize(%{stream_key: stream_key, connection_id: connection_id})
      when is_binary(stream_key) and is_binary(connection_id) do
    Ingest.authorize_rtmp(stream_key, connection_id)
  end

  def authorize(_params), do: {:error, :invalid_request}

  def disconnect(connection_id) when is_binary(connection_id) do
    Ingest.stop_session(connection_id)
  end

  def disconnect(_connection_id), do: {:error, :invalid_request}
end
