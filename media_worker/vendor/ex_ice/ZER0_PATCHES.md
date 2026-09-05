Vendored from the Hex ex_ice 0.16.1 package (Apache-2.0; see LICENSE).
Upstream: https://github.com/elixir-webrtc/ex_ice

Local change: get_or_create_local_cand/3 preserves the TURN relay candidate
on successful connectivity checks, including when XOR-MAPPED-ADDRESS differs
from the allocation address. The original path raises KeyError looking up the
public relay address in local_preferences (which is keyed by local interfaces).
Creating a plain peer-reflexive candidate would also discard the TURN client.

The media worker uses this tracked path dependency in local and Docker builds.
Regression coverage: media_worker/test/ice_relay_test.exs.
Remove this override when an upstream release covers the same case.
