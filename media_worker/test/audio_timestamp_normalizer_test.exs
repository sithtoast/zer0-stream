defmodule Zer0Media.AudioTimestampNormalizerTest do
  use ExUnit.Case, async: true

  alias Zer0Media.AudioTimestampNormalizer

  test "maps the first timestamp to zero" do
    assert AudioTimestampNormalizer.correct_timestamp(5_000, 5_000, 1.0) == 0
  end

  test "applies a clock-rate correction to elapsed timestamps" do
    assert AudioTimestampNormalizer.correct_timestamp(25_792_000_000, 0, 1.008) == 25_998_336_000
  end

  test "preserves nil timestamps" do
    assert AudioTimestampNormalizer.correct_timestamp(nil, 0, 1.008) == nil
  end
end
