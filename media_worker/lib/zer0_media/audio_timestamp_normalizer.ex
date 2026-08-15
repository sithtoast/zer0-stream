defmodule Zer0Media.AudioTimestampNormalizer do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: %Membrane.AAC{})
  def_output_pad(:output, accepted_format: %Membrane.AAC{})

  defstruct rate: 1.0, input_origin: nil

  @type t :: %__MODULE__{rate: float(), input_origin: Membrane.Time.t() | nil}

  @impl true
  def handle_init(_ctx, %__MODULE__{} = opts) do
    {[], %__MODULE__{rate: opts.rate}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case Membrane.Buffer.get_dts_or_pts(buffer) do
      nil ->
        {[buffer: {:output, buffer}], state}

      timestamp ->
        origin = state.input_origin || timestamp

        corrected_buffer = %{
          buffer
          | pts: correct_timestamp(buffer.pts, origin, state.rate),
            dts: correct_timestamp(buffer.dts, origin, state.rate)
        }

        {[buffer: {:output, corrected_buffer}], %{state | input_origin: origin}}
    end
  end

  @spec correct_timestamp(Membrane.Time.t() | nil, Membrane.Time.t(), float()) ::
          Membrane.Time.t() | nil
  def correct_timestamp(nil, _origin, _rate), do: nil
  def correct_timestamp(timestamp, origin, rate), do: round((timestamp - origin) * rate)
end
