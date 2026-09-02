defmodule Zer0Media.LivePipelineSupervisor do
  @moduledoc """
  Owns each session's `Zer0Media.LivePipeline` so a crash in one stream's
  pipeline (e.g. a WebRTC restart loop, or any other Membrane pipeline crash)
  can never propagate up and take down the whole application — mirrors
  `Zer0Media.BoomboxSessionSupervisor`'s isolation for the boombox path.
  """
  use DynamicSupervisor

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a `Zer0Media.LivePipeline` as a supervised, isolated child.

  `Membrane.Pipeline.start_link/2` returns `{:ok, pipeline_supervisor_pid,
  pipeline_pid}` (a 3-tuple), which `DynamicSupervisor.start_child/2` passes
  through unchanged as `{:ok, pid, extra}` — callers must match on the
  3-tuple, not `{:ok, pid}`.
  """
  def start_pipeline(pipeline_opts) do
    spec = %{
      id: Zer0Media.LivePipeline,
      start: {Membrane.Pipeline, :start_link, [Zer0Media.LivePipeline, pipeline_opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
