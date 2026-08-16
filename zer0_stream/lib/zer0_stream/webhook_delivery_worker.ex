defmodule Zer0Stream.WebhookDeliveryWorker do
  use GenServer

  @poll_interval_ms 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    send(self(), :deliver)
    {:ok, nil}
  end

  @impl true
  def handle_info(:deliver, state) do
    Zer0Stream.LifecycleWebhook.deliver_pending()
    Process.send_after(self(), :deliver, @poll_interval_ms)
    {:noreply, state}
  end
end
