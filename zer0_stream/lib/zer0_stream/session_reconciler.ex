defmodule Zer0Stream.SessionReconciler do
  @moduledoc """
  Periodically ends live stream sessions that have gone stale (no heartbeat /
  activity for longer than `:stream_stale_after_seconds`), emitting a
  `stream.stopped` webhook for each. This is a safety net for sessions whose
  media worker died or disconnected uncleanly and never issued a clean stop.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    Process.send_after(self(), :reconcile, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    stale_after = stale_after_seconds()
    count = Zer0Stream.Ingest.reconcile_stale_sessions(stale_after)

    if count > 0 do
      Logger.info("SessionReconciler ended #{count} stale session(s)")
    end

    Process.send_after(self(), :reconcile, state.interval)
    {:noreply, state}
  end

  defp interval_ms do
    Application.get_env(:zer0_stream, :session_reconcile_interval_ms, @default_interval_ms)
  end

  defp stale_after_seconds do
    Application.get_env(:zer0_stream, :stream_stale_after_seconds, 300)
  end
end
