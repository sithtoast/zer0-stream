defmodule Zer0Media.BoomboxSessionSupervisor do
  use DynamicSupervisor

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_session(session_id) do
    spec = {Zer0Media.BoomboxSession, session_id: session_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
