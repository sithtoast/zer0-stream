defmodule Zer0Media.BroadcastTee do
  @moduledoc """
  Splits a stream into a primary output (always forwarded) and an optional
  secondary output (forwarded only when it has demand).

  Unlike `Tee.Parallel` (which waits for all outputs to demand) or `Tee.Master`
  (which pushes to copies and can block), this filter **always** forwards to the
  primary pad. The secondary pad gets a copy only when its downstream is
  demanding — if it falls behind, the copy is silently dropped.
  """
  use Membrane.Filter

  def_input_pad :input,
    availability: :always,
    flow_control: :auto,
    accepted_format: _any

  def_output_pad :primary,
    availability: :always,
    flow_control: :auto,
    accepted_format: _any

  def_output_pad :secondary,
    availability: :on_request,
    flow_control: :auto,
    accepted_format: _any

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{format: nil}}
  end

  @impl true
  def handle_stream_format(_pad, format, _ctx, state) do
    {[stream_format: {:primary, format}], %{state | format: format}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:secondary, _id) = pad, _ctx, %{format: fmt} = state)
      when not is_nil(fmt) do
    {[stream_format: {pad, fmt}], state}
  end

  @impl true
  def handle_pad_added(_pad, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # `forward` sends to *all* output pads.  For `:auto` pads the framework
    # checks demand independently per pad — if the secondary isn't demanding
    # (e.g. its downstream fell behind), only the primary gets the buffer.
    {[forward: buffer], state}
  end
end
