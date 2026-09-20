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
end
