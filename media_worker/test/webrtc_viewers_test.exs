Code.require_file("support/viewer_pipeline.ex", __DIR__)

defmodule Zer0Media.WebRTCViewersTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.Testing
  alias Zer0Media.WebRTCSignalingWebSock, as: Socket

  test "two viewers receive separate offers and one disconnect leaves the other running" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: Zer0Media.Test.ViewerPipeline)
    owner = self()

    peers =
      for id <- ["a", "b"] do
        start_supervised!(%{
          id: id,
          start:
            {Task, :start_link,
             [
               fn ->
                 {:push, {:text, config}, state} =
                   Socket.init(%{pipeline: pipeline, viewer_id: id})

                 assert %{"type" => "ice_servers"} = Jason.decode!(config)
                 send(owner, {:ready, self(), state.signaling.pid})

                 receive do
                   {:membrane_webrtc_signaling, _, %{"type" => "sdp_offer"} = offer, _} ->
                     send(owner, {:offer, self(), offer})
                 end

                 receive do
                   :stop -> Socket.terminate(:normal, state)
                 end
               end
             ]},
          restart: :temporary
        })
      end

    [a, b] = peers
    assert_receive {:ready, ^a, relay_a}, 2000
    assert_receive {:ready, ^b, relay_b}, 2000
    refute relay_a == relay_b
    assert_receive {:offer, ^a, _}, 2000
    assert_receive {:offer, ^b, _}, 2000
    ref = Process.monitor(relay_a)
    send(a, :stop)
    assert_receive {:DOWN, ^ref, :process, ^relay_a, _}, 2000
    assert_child_terminated(pipeline, {:webrtc, a})
    # Synchronize through the live relay; no third-peer registration or crash.
    assert %{peer_a: _, peer_b: _} = :sys.get_state(relay_b)
    assert %{custom_pipeline_state: %{viewers: viewers}} = :sys.get_state(pipeline).internal_state
    assert Map.has_key?(viewers, b)
    refute Map.has_key?(viewers, a)
  end
end
