defmodule Zer0Media.TimestampScalerTest do
  use ExUnit.Case, async: true
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.{Buffer, Testing}

  test "default timing preserves 60 fps and the encoded bytes per second" do
    buffers =
      for i <- 0..60,
          do: %Buffer{
            payload: <<i>>,
            pts: 5_000_000_000 + round(i * 1_000_000_000 / 60),
            dts: 5_000_000_000 + round(i * 1_000_000_000 / 60)
          }

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Testing.Source{output: buffers})
          |> child(:scaler, Zer0Media.TimestampScaler)
          |> child(:sink, Testing.Sink)
      )

    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<0>>, pts: 0})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<60>>, pts: 1_000_000_000})
  end
end
