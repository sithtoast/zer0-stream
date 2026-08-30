defmodule Zer0Media.SessionHeartbeatReporter do
  @moduledoc """
  Periodically reports a liveness heartbeat to the control plane for every live
  RTMP session tracked by `Zer0Media.SessionTracker`. This lets the control
  plane's reconciler distinguish a healthy-but-quiet stream (worker alive) from a
  dead one, independent of viewer count.
  """

  use GenServer

  require Logger

  @default_interval_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    schedule()

    Zer0Media.SessionTracker.sessions()
    |> Enum.each(fn session_id ->
      case Zer0Media.ControlPlane.heartbeat(session_id) do
        :ok ->
          :ok

        {:error, {:control_plane, 404}} ->
          # Session no longer live on the control plane; stop tracking it.
          Logger.debug("session #{session_id} no longer live; dropping heartbeat")
          Zer0Media.SessionTracker.untouch(session_id)

        {:error, reason} ->
          Logger.warning("heartbeat failed for session #{session_id}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :heartbeat, interval_ms())

  defp interval_ms do
    (Application.get_env(:zer0_media, :session_heartbeat_interval_ms) ||
       System.get_env("SESSION_HEARTBEAT_INTERVAL_MS") || @default_interval_ms)
    |> parse_positive_integer(@default_interval_ms)
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
