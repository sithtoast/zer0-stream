defmodule Zer0Media.Test.ViewerPipeline do
  use Membrane.Pipeline

  # Exercise the production viewer lifecycle without an external RTMP publisher.
  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{session_id: "test-viewers", viewers: %{}}}
  end

  @impl true
  defdelegate handle_info(message, ctx, state), to: Zer0Media.LivePipeline
  @impl true
  defdelegate handle_child_notification(message, child, ctx, state), to: Zer0Media.LivePipeline
  @impl true
  defdelegate handle_child_terminated(child, ctx, state), to: Zer0Media.LivePipeline
  @impl true
  defdelegate handle_crash_group_down(group, ctx, state), to: Zer0Media.LivePipeline
end
