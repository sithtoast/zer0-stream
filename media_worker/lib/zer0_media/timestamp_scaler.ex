defmodule Zer0Media.TimestampScaler do
  @moduledoc """
  Rebases video PTS/DTS to start at zero and scales them by a fixed factor.

  Used to correct a mismatched video timebase (e.g. an RTMP publisher that
  stamps 60fps video at a 30fps rate, doubling the timestamps) so the HLS
  packager can keep audio and video aligned. Rebasing to zero keeps the video
  timeline in sync with `Zer0Media.AudioTimestampNormalizer`, which rebases the
  audio timeline to zero.
  """
  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  defstruct scale: 1.0, origin: nil

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, _ctx, %{origin: nil} = state) do
    origin = buffer.pts || buffer.dts || 0
    buffer = %{buffer | pts: 0, dts: 0}
    {[buffer: {:output, buffer}], %{state | origin: origin}}
  end

  def handle_buffer(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    buffer = %{
      buffer
      | pts: scale(buffer.pts, state.origin, state.scale),
        dts: scale(buffer.dts, state.origin, state.scale)
    }

    {[buffer: {:output, buffer}], state}
  end

  defp scale(nil, _origin, _scale), do: nil
  defp scale(timestamp, origin, scale), do: round((timestamp - origin) * scale)
end
