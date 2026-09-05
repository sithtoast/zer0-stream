defmodule Zer0Media.BroadcastTee do
  @moduledoc """
  Splits a stream into a primary output (always forwarded) and an optional
  secondary outputs (forwarded only when each has demand).

  Unlike `Tee.Parallel` (which waits for all outputs to demand) or `Tee.Master`
  (which pushes to copies and can block), this filter **always** forwards to the
  primary pad. The secondary pad gets a copy only when its downstream is
  demanding — if it falls behind, the copy is silently dropped.
  """
  use Membrane.Filter

  def_input_pad(:input,
    availability: :always,
    flow_control: :auto,
    accepted_format: _any
  )

  def_output_pad(:primary,
    availability: :always,
    flow_control: :auto,
    accepted_format: _any
  )

  def_output_pad(:secondary,
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{format: nil}}
  end

  @impl true
  def handle_stream_format(_pad, format, ctx, state) do
    actions = for {pad, %{direction: :output}} <- ctx.pads, do: {:stream_format, {pad, format}}
    {actions, %{state | format: format}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:secondary, _id) = pad, _ctx, %{format: fmt} = state)
      when not is_nil(fmt) do
    {[stream_format: {pad, fmt}], state}
  end

  @impl true
  def handle_pad_added(_pad, _ctx, state), do: {[], state}

  @impl true
  def handle_demand(_pad, _size, :buffers, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    # Manual secondary pads do not participate in the primary auto-demand path.
    copies =
      for {Pad.ref(:secondary, _) = pad, %{demand: demand}} <- ctx.pads,
          demand > 0,
          do: {:buffer, {pad, buffer}}

    {[buffer: {:primary, buffer}] ++ copies, state}
  end
end
