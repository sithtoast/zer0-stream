defmodule Zer0Media.ViewerMetricsReporter do
  use GenServer

  require Logger

  @default_snapshot_interval_ms 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule_report()
    {:ok, state}
  end

  @impl true
  def handle_info(:report, state) do
    schedule_report()

    Zer0Media.ViewerTracker.samples()
    |> Enum.each(fn {session_id, viewer_count} ->
      case Zer0Media.ControlPlane.record_viewer_sample(session_id, viewer_count) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("unable to record viewer sample: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  defp schedule_report do
    Process.send_after(self(), :report, snapshot_interval_milliseconds())
  end

  defp snapshot_interval_milliseconds do
    (Application.get_env(:zer0_media, :viewer_snapshot_interval_ms) ||
       System.get_env("VIEWER_SNAPSHOT_INTERVAL_MS") || @default_snapshot_interval_ms)
    |> parse_positive_integer(@default_snapshot_interval_ms)
  end

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default
end