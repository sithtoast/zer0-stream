defmodule Zer0Media.LivePipelineTest do
  use ExUnit.Case, async: true

  alias Zer0Media.LivePipeline

  test "normal child exit does not repeat a disconnect removal" do
    peer = self()

    ctx = %{
      exit_reason: :normal,
      children: %{
        {:opus_encoder, peer} => %{group: {:webrtc_output, peer}, terminating?: true}
      }
    }

    state = %{viewers: %{}}
    assert {[], ^state} = LivePipeline.handle_child_terminated({:webrtc, peer}, ctx, state)
  end

  test "unexpected normal exit removes only live children in its own group" do
    peer = self()
    monitor = Process.monitor(peer)

    ctx = %{
      exit_reason: :normal,
      children: %{
        :live => %{group: {:webrtc_output, peer}, terminating?: false},
        :already_removing => %{group: {:webrtc_output, peer}, terminating?: true},
        :other_viewer => %{group: {:webrtc_output, :other}, terminating?: false}
      }
    }

    state = %{viewers: %{peer => %{monitor: monitor}, :other => %{monitor: nil}}}

    assert {[remove_children: [:live]], result} =
             LivePipeline.handle_child_terminated({:webrtc, peer}, ctx, state)

    assert result.viewers == %{other: %{monitor: nil}}
  end

  describe "ice_ip_filter/1" do
    test "keeps IPv4 and IPv6 loopback" do
      assert LivePipeline.ice_ip_filter({127, 0, 0, 1})
      assert LivePipeline.ice_ip_filter({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "keeps ordinary public/private addresses" do
      assert LivePipeline.ice_ip_filter({192, 168, 1, 10})
      assert LivePipeline.ice_ip_filter({10, 0, 0, 5})
      assert LivePipeline.ice_ip_filter({0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1})
    end

    test "drops IPv4 link-local" do
      refute LivePipeline.ice_ip_filter({169, 254, 1, 1})
    end

    test "drops IPv6 link-local" do
      refute LivePipeline.ice_ip_filter({0xFE, 0x80, 0, 0, 0, 0, 0, 1})
    end

    test "drops IPv6 multicast" do
      refute LivePipeline.ice_ip_filter({0xFF, 0x02, 0, 0, 0, 0, 0, 1})
    end
  end
end
