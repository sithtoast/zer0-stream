defmodule Zer0Media.AudioTimestampNormalizer do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: %Membrane.AAC{})
  def_output_pad(:output, accepted_format: %Membrane.AAC{})

  defstruct rate: 1.0

  @type t :: %__MODULE__{rate: float()}

  @impl true
  def handle_init(_ctx, %__MODULE__{} = opts) do
    {[], %__MODULE__{rate: opts.rate}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @spec correct_timestamp(Membrane.Time.t() | nil, Membrane.Time.t(), float()) ::
          Membrane.Time.t() | nil
  def correct_timestamp(nil, _origin, _rate), do: nil
  def correct_timestamp(timestamp, origin, rate), do: round((timestamp - origin) * rate)
end
