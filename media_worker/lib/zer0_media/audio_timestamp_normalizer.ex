defmodule Zer0Media.AudioTimestampNormalizer do
  @moduledoc """
  Rebases AAC PTS/DTS to start at zero and applies a linear clock-rate
  correction so the audio timeline matches the video timeline.

  Some publishers (notably OBS) drive audio and video from separate,
  unsynchronized capture threads, producing a small steady clock-rate
  difference (measured ~0.8% for the current setup). Without correction the
  audio/video gap grows over time and eventually trips the HLS muxer's sync
  tolerance, stalling segment production. Set `rate` to the measured ratio
  (e.g. `1.008`) via `AAC_TIMESTAMP_RATE`.
  """
  use Membrane.Filter

  def_input_pad(:input, accepted_format: %Membrane.AAC{})
  def_output_pad(:output, accepted_format: %Membrane.AAC{})

  defstruct rate: 1.0, origin: nil

  @type t :: %__MODULE__{rate: float()}

  @impl true
  def handle_init(_ctx, %__MODULE__{} = opts) do
    {[], %__MODULE__{rate: opts.rate, origin: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{origin: nil} = state) do
    origin = buffer.pts || buffer.dts || 0
    buffer = %{buffer | pts: 0, dts: 0}
    {[buffer: {:output, buffer}], %{state | origin: origin}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    buffer = %{
      buffer
      | pts: correct_timestamp(buffer.pts, state.origin, state.rate),
        dts: correct_timestamp(buffer.dts, state.origin, state.rate)
    }

    {[buffer: {:output, buffer}], state}
  end

  @spec correct_timestamp(Membrane.Time.t() | nil, Membrane.Time.t(), float()) ::
          Membrane.Time.t() | nil
  def correct_timestamp(nil, _origin, _rate), do: nil
  def correct_timestamp(timestamp, origin, rate), do: round((timestamp - origin) * rate)
end
