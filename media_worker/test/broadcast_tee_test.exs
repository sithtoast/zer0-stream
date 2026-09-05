defmodule Zer0Media.BroadcastTeeTest do
  use ExUnit.Case, async: true
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.{Pad, Testing}
  require Pad

  test "an undemanding viewer cannot stop HLS or another viewer" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, %Testing.Source{output: Enum.map(1..100, &<<&1>>)})
          |> child(:tee, Zer0Media.BroadcastTee)
          |> via_out(:primary)
          |> child(:hls, Testing.Sink),
          get_child(:tee)
          |> via_out(Pad.ref(:secondary, :slow))
          |> child(:slow, %Testing.Sink{autodemand: false}),
          get_child(:tee)
          |> via_out(Pad.ref(:secondary, :fast))
          |> child(:fast, Testing.Sink)
        ]
      )

    assert_sink_buffer(pipeline, :hls, %Membrane.Buffer{payload: <<100>>})
    assert_sink_buffer(pipeline, :fast, %Membrane.Buffer{})
    refute_sink_buffer(pipeline, :slow, %Membrane.Buffer{}, 50)
  end

  test "format changes reach every viewer" do
    pads = %{
      :primary => %{direction: :output},
      Pad.ref(:secondary, :a) => %{direction: :output},
      Pad.ref(:secondary, :b) => %{direction: :output}
    }

    format = %Membrane.RemoteStream{}

    {actions, _} =
      Zer0Media.BroadcastTee.handle_stream_format(:input, format, %{pads: pads}, %{format: nil})

    assert length(actions) == 3
    assert {:stream_format, {Pad.ref(:secondary, :b), format}} in actions
  end
end
