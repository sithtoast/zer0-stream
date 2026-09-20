defmodule Zer0Media.LLHLS.Generation do
  @moduledoc "A supervised origin and rendition states for one immutable publisher incarnation."
  use Supervisor, restart: :temporary
  alias Zer0Media.LLHLS.{Origin, Stream}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    session = Keyword.fetch!(opts, :session)
    generation = Keyword.fetch!(opts, :generation)
    owner = Keyword.fetch!(opts, :owner)

    streams =
      for rendition <- config.renditions do
        Supervisor.child_spec(
          {Stream,
           owner: owner,
           name: Origin.via({session, generation, rendition}),
           require_media?: true,
           max_waiters: config.max_waiters,
           playlist: [target_duration: config.target_duration, part_target: config.part_duration],
           render: [blocking?: true, preload_hint?: true]},
          id: rendition
        )
      end

    # Never restart a lost state under the same generation URL. The origin
    # monitors temporary rendition children and fails the generation as a unit.
    Supervisor.init(streams ++ [{Origin, opts}], strategy: :one_for_one, max_restarts: 0)
  end
end
