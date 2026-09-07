# Local patches to membrane_rtmp_plugin 0.29.5

Upstream: https://github.com/membraneframework/membrane_rtmp_plugin
License: Apache-2.0 (see LICENSE).

- Start clients as temporary children of a DynamicSupervisor owned by the RTMP
  server. A client crash cannot terminate the listener or other clients; stopping
  the server also stops its clients. Failed clients are never restarted against
  dead sockets.
- Reject parser exceptions with a normal connection shutdown and a fixed warning,
  without logging packet contents. Application callback failures still surface.
- Stop client processes when TCP/TLS sockets close, after notifying the handler.
- Omit application paths and stream keys from the client timeout warning.

Regression coverage: media_worker/test/rtmp_server_test.exs.
