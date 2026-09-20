defmodule Zer0Media.MediaConfig do
  @moduledoc """
  Validated media timing configuration. Public configuration uses milliseconds;
  Membrane receives nanoseconds through `Membrane.Time` conversions.
  """
  require Logger

  def load!(env \\ System.get_env()) do
    segment_ms = duration_ms!(env)
    part_ms = positive_integer!(env["LLHLS_PART_DURATION_MS"] || "200", "LLHLS_PART_DURATION_MS")

    if part_ms > segment_ms do
      raise ArgumentError, "LLHLS_PART_DURATION_MS must not exceed HLS_SEGMENT_DURATION_MS"
    end

    %{
      segment_duration: Membrane.Time.milliseconds(segment_ms),
      part_duration: Membrane.Time.milliseconds(part_ms)
    }
  end

  def configure! do
    config = load!()

    if System.get_env("HLS_SEGMENT_DURATION") do
      Logger.warning(
        "HLS_SEGMENT_DURATION is deprecated (nanoseconds); use HLS_SEGMENT_DURATION_MS"
      )
    end

    Application.put_env(:zer0_media, :media_timing, config)
    config
  end

  def timing, do: Application.fetch_env!(:zer0_media, :media_timing)

  defp duration_ms!(env) do
    case {env["HLS_SEGMENT_DURATION_MS"], env["HLS_SEGMENT_DURATION"]} do
      {nil, nil} ->
        1000

      {ms, nil} ->
        positive_integer!(ms, "HLS_SEGMENT_DURATION_MS")

      {nil, ns} ->
        ns = positive_integer!(ns, "HLS_SEGMENT_DURATION", 60_000_000_000)

        if rem(ns, 1_000_000) != 0 do
          raise ArgumentError, "HLS_SEGMENT_DURATION must be whole milliseconds in nanoseconds"
        end

        div(ns, 1_000_000)

      {_, _} ->
        raise ArgumentError,
              "set only HLS_SEGMENT_DURATION_MS, not both segment duration variables"
    end
  end

  defp positive_integer!(value, name, max \\ 60_000) do
    unless Regex.match?(~r/^[0-9]+$/, value),
      do: raise(ArgumentError, "#{name} must be a positive decimal integer")

    case Integer.parse(value) do
      {value, ""} when value > 0 and value <= max -> value
      _ -> raise ArgumentError, "#{name} must be a positive decimal integer"
    end
  end
end
