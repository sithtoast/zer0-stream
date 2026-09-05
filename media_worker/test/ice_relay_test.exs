defmodule Zer0Media.ICERelayTest do
  use ExUnit.Case, async: true
  alias ExICE.Priv.{Candidate, CandidatePair, ICEAgent}
  alias ExSTUN.Message
  alias ExSTUN.Message.{Type, Attribute.XORMappedAddress}

  test "a relayed check with a different mapped address keeps TURN routing" do
    # Feed the authenticated response after TURN decapsulation through the
    # packet handler. Only the local interface has a priority preference.
    socket = make_ref()
    local = {192, 168, 1, 9}
    relay_ip = {203, 0, 113, 10}
    remote_ip = {198, 51, 100, 20}
    transport = ExICE.Priv.Transport.UDP

    host =
      Candidate.Host.new(
        address: local,
        port: 5000,
        base_address: local,
        base_port: 5000,
        priority: 100,
        transport_module: transport,
        socket: socket
      )

    relay =
      Candidate.Relay.new(
        address: relay_ip,
        port: 6000,
        base_address: relay_ip,
        base_port: 6000,
        priority: 90,
        transport_module: transport,
        socket: socket,
        client: :turn_client_must_be_preserved
      )

    remote =
      ExICE.Candidate.new(:host, address: remote_ip, port: 7000, priority: 100, transport: :udp)

    pair = CandidatePair.new(relay, remote, :controlled, :in_progress)
    request = Message.new(%Type{class: :request, method: :binding}, [])

    response =
      Message.new(
        %Type{class: :success_response, method: :binding},
        [%XORMappedAddress{address: {198, 51, 100, 30}, port: 8000}]
      )

    response =
      %{response | transaction_id: request.transaction_id}
      |> Message.with_integrity("remote-password")
      |> Message.with_fingerprint()

    agent = %ICEAgent{
      role: :controlled,
      state: :checking,
      remote_pwd: "remote-password",
      local_preferences: %{local => 7441},
      local_cands: %{host.base.id => host, relay.base.id => relay},
      remote_cands: %{remote.id => remote},
      checklist: %{pair.id => pair},
      conn_checks: %{
        request.transaction_id => %{pair_id: pair.id, raw_req: Message.encode(request)}
      }
    }

    result = ICEAgent.handle_udp(agent, socket, remote_ip, 7000, Message.encode(response))
    assert result.checklist[pair.id].state == :succeeded
    assert result.checklist[pair.id].valid?
    assert result.local_cands[relay.base.id] == relay
    assert map_size(result.local_cands) == 2
    Process.cancel_timer(result.checklist[pair.id].keepalive_timer)
  end
end
