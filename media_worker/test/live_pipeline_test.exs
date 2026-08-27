defmodule Zer0Media.LivePipelineTest do
  use ExUnit.Case, async: true

  alias Zer0Media.LivePipeline

  describe "ice_ip_filter/1" do
    test "keeps IPv4 and IPv6 loopback" do
      assert LivePipeline.ice_ip_filter({127, 0, 0, 1})
      assert LivePipeline.ice_ip_filter({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "keeps ordinary public/private addresses" do
      assert LivePipeline.ice_ip_filter({192, 168, 1, 10})
      assert LivePipeline.ice_ip_filter({10, 0, 0, 5})
      assert LivePipeline.ice_ip_filter({0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1})
    end

    test "drops IPv4 link-local" do
      refute LivePipeline.ice_ip_filter({169, 254, 1, 1})
    end

    test "drops IPv6 link-local" do
      refute LivePipeline.ice_ip_filter({0xfe, 0x80, 0, 0, 0, 0, 0, 1})
    end

    test "drops IPv6 multicast" do
      refute LivePipeline.ice_ip_filter({0xff, 0x02, 0, 0, 0, 0, 0, 1})
    end
  end
end
