defmodule Zer0Media.MediaConfigTest do
  use ExUnit.Case, async: true
  alias Zer0Media.MediaConfig

  test "defaults preserve existing segment timing without enabling LL-HLS" do
    assert MediaConfig.load!(%{}) == %{
             segment_duration: Membrane.Time.seconds(1),
             part_duration: Membrane.Time.milliseconds(200)
           }
  end

  test "explicit milliseconds convert at the Membrane boundary" do
    assert MediaConfig.load!(%{
             "HLS_SEGMENT_DURATION_MS" => "2000",
             "LLHLS_PART_DURATION_MS" => "250"
           }) ==
             %{
               segment_duration: Membrane.Time.seconds(2),
               part_duration: Membrane.Time.milliseconds(250)
             }
  end

  test "legacy nanoseconds retain their meaning" do
    assert MediaConfig.load!(%{"HLS_SEGMENT_DURATION" => "4000000000"}).segment_duration ==
             Membrane.Time.seconds(4)
  end

  test "invalid, ambiguous and inconsistent settings fail before starting children" do
    for env <- [
          %{"HLS_SEGMENT_DURATION_MS" => "0"},
          %{"HLS_SEGMENT_DURATION_MS" => "+1"},
          %{"HLS_SEGMENT_DURATION_MS" => "60001"},
          %{"HLS_SEGMENT_DURATION_MS" => "2s"},
          %{"HLS_SEGMENT_DURATION_MS" => "-1"},
          %{"LLHLS_PART_DURATION_MS" => ""},
          %{"LLHLS_PART_DURATION_MS" => "1.5"},
          %{"LLHLS_PART_DURATION_MS" => "1001"},
          %{"HLS_SEGMENT_DURATION" => "1"},
          %{"HLS_SEGMENT_DURATION_MS" => "1000", "HLS_SEGMENT_DURATION" => "1000000000"}
        ] do
      assert_raise ArgumentError, fn -> MediaConfig.load!(env) end
    end
  end

  test "LL-HLS is explicitly enabled with bounded origin settings" do
    timing = MediaConfig.load!(%{})
    refute MediaConfig.load_llhls!(%{}, timing).enabled?
    enabled = MediaConfig.load_llhls!(%{"LLHLS_ENABLED" => "true"}, timing)
    assert enabled.enabled?
    assert enabled.target_duration == Membrane.Time.seconds(6)
    assert enabled.retention_ms == 60_000
    assert enabled.max_waiters == 5000

    for env <- [
          %{"LLHLS_ENABLED" => "yes"},
          %{"LLHLS_TARGET_DURATION_MS" => "1500"},
          %{"LLHLS_TARGET_DURATION_MS" => "1000"},
          %{"LLHLS_RETENTION_MS" => "47999"},
          %{"LLHLS_MAX_WAITERS" => "100001"},
          %{"LLHLS_PART_DURATION_MS" => "49"}
        ] do
      env = Map.merge(%{"LLHLS_ENABLED" => "true"}, env)
      assert_raise ArgumentError, fn -> MediaConfig.load_llhls!(env, MediaConfig.load!(env)) end
    end
  end

  test "disabled LL-HLS preserves long standard-HLS timing" do
    timing = MediaConfig.load!(%{"HLS_SEGMENT_DURATION_MS" => "10000"})
    refute MediaConfig.load_llhls!(%{}, timing).enabled?
  end
end
