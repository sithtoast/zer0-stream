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

    Application.put_env(:zer0_media, :llhls, load_llhls!(System.get_env(), config))
    Application.put_env(:zer0_media, :media_timing, config)
    config
  end

  def timing, do: Application.fetch_env!(:zer0_media, :media_timing)

  def llhls, do: Application.fetch_env!(:zer0_media, :llhls)

  def load_llhls!(env, timing) do
    enabled? =
      case env["LLHLS_ENABLED"] do
        value when value in [nil, "false", "0"] -> false
        value when value in ["true", "1"] -> true
        _ -> raise ArgumentError, "LLHLS_ENABLED must be true or false"
      end

    target_ms =
      positive_integer!(env["LLHLS_TARGET_DURATION_MS"] || "6000", "LLHLS_TARGET_DURATION_MS")

    retention_ms =
      positive_integer!(env["LLHLS_RETENTION_MS"] || "60000", "LLHLS_RETENTION_MS", 600_000)

    max_waiters =
      positive_integer!(env["LLHLS_MAX_WAITERS"] || "5000", "LLHLS_MAX_WAITERS", 100_000)

    if enabled? and
         (rem(target_ms, 1000) != 0 or target_ms * 1_000_000 <= timing.segment_duration or
            retention_ms < 8 * target_ms or timing.part_duration < 50_000_000) do
      raise ArgumentError,
            "LL-HLS requires a whole-second target above the segment minimum, retention >= 8 targets and parts >= 50ms"
    end

    %{
      enabled?: enabled?,
      target_duration: Membrane.Time.milliseconds(target_ms),
      part_duration: timing.part_duration,
      retention_ms: retention_ms,
      max_waiters: max_waiters,
      renditions: ["audio", "video"]
    }
  end

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
