defmodule Zer0Media.WebRTCBinTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.Testing
  alias Zer0Media.WebRTCBin

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  test "does not gate the parent pipeline's data flow while the inner WebRTC sink is incomplete" do
    port = free_port()

    {:ok, _sup, pipeline} =
      Testing.Pipeline.start_link(spec: [
        child(:src, %Testing.Source{output: [<<1>>, <<2>>, <<3>>]})
        |> child(:sink, Testing.Sink),
        {child(:webrtc, %WebRTCBin{
           signaling: {:websocket, [port: port]},
           video_codec: [:h264]
         }), group: :webrtc_output, crash_group_mode: :temporary}
      ])

    # The WebRTCBin wraps a WebRTC.Sink that stays `setup: :incomplete` until a
    # viewer connects. If the bin did not complete its own setup immediately, the
    # whole pipeline would stall and no buffers would reach the sink.
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: <<1>>}, 2000)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: <<2>>}, 2000)

    Testing.Pipeline.terminate(pipeline)
  end
end
