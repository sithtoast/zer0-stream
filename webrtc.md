# WebRTC playback

## Status

**Validated as a proof of concept (2026-08-23).** WebRTC output from the Boombox
runtime, delivered over a WebSocket signaling channel to a browser
`RTCPeerConnection`, produces **sub-second latency** — a large improvement over
the ~5s HLS path.

Key POC findings:

- H.264 passthrough (`video_codec: [:h264]`) avoids the frame-dropping that
  happens when the sink transcodes H.264 -> VP8. The RTMP input is already
  H.264, so passing it through is both stable and cheap.
- The WebRTC Sink sends the SDP offer; the browser answers it.
- The signaling port is dynamic per session (like the RTMP relay port) to avoid
  collisions across OBS reconnects.
- A one-time ICE connectivity-check timeout can occur on the first connect
  (mostly IPv6 candidate noise / mDNS `.local` timeouts); a retry connects
  cleanly.

## Why WebRTC

- Standard HLS has a latency floor of ~2-5s because the player must buffer whole
  segments behind the live edge. With 1s segments we measured ~5s.
- LL-HLS (partial segments) helps but is browser-inconsistent and still bounded
  by HLS semantics.
- WebRTC streams directly over `RTCPeerConnection`, giving sub-second latency.

## Target architecture

```
OBS --RTMP--> media_worker (Membrane pipeline)
                 |
                 +-- tee --> HLS (HTTPAdaptiveStream.SinkBin)  -> HLS origin
                 |
                 +-- tee --> WebRTC (WebRTC.Sink) + WebSocket signaling -> browser
```

- The media worker runs a single Membrane pipeline per session that splits the
  stream to **both** HLS and WebRTC simultaneously (no more "one output" limit
  of `Boombox.run/1`).
- WebRTC signaling uses the WebSocket server (`SimpleWebSocketServer`) for
  SDP/ICE exchange.
- The control plane issues WebRTC playback URLs/tokens, mirroring the HLS
  playback-token flow.
- The frontend (twitch-elixir) uses a WebRTC player with HLS fallback.

## POC vs production

| Concern | POC | Production |
|---|---|---|
| Outputs | WebRTC replaces HLS for the session | HLS + WebRTC simultaneously (tee) |
| Signaling port | Dynamic, read from the log | Discovered via control plane / registry |
| Auth | None | Signed WebRTC playback token |
| Player | Standalone test page | Integrated into channel page + HLS fallback |
| Packaging | Patched vendored Boombox (gitignored) | Tracked pipeline or Boombox fork |
| ICE | Default STUN, IPv6 noise | Filter IPv6, configurable STUN/TURN |

## Production steps

1. **Tee-based pipeline** — build a tracked Membrane pipeline in `media_worker`
   that feeds both HLS and WebRTC from one RTMP source.

   **Status: implemented** in `media_worker/lib/zer0_media/live_pipeline.ex`
   (`Zer0Media.LivePipeline`). Each track is split with `Tee.Master` (HLS is the
   `:master` output, WebRTC is a passive `:copy`). HLS uses
   `HTTPAdaptiveStream.SinkBin`; WebRTC uses `WebRTC.Sink` with H.264 passthrough.
   A `TimestampScaler` (video scale 0.5) corrects the publisher's 2x video
   timebase.

   **WebRTC legs are linked on demand.** They are not wired in `handle_init`;
   they are linked when the sink reports `:new_tracks` (a viewer has actually
   joined and negotiated). This prevents the push-mode tee `:copy` pads from
   backing up and overflowing (killing HLS) when no viewer is watching.

   **The WebRTC sink is wrapped in `Zer0Media.WebRTCBin`.** The WebRTC Sink
   returns `setup: :incomplete` until a viewer connects, and in Membrane an
   incomplete child gates the whole pipeline's data flow (stalling HLS). The
   wrapper bin completes its own setup immediately, so HLS runs independently,
   while relaying signaling and linking pads to the inner sink. The WebRTC bin
   lives in a temporary crash group so a WebRTC failure doesn't take HLS down.
2. **Make packaging permanent** — either fork Boombox as a git dependency with
   the patches, or move HLS/WebRTC packaging into tracked `media_worker` code
   (preferred; aligns with the plan's "Membrane as the media pipeline" goal).
3. **Control plane** — issue signed WebRTC playback URLs/tokens and expose the
   current signaling URL.
4. **Frontend** — integrate a WebRTC player into the channel page with automatic
   HLS fallback.
5. **Harden ICE** — filter IPv6 candidates, make STUN/TURN configurable.

   **Status: partial.** `LivePipeline` now passes an `ice_ip_filter` to the
   `WebRTC.Sink` that drops IPv6 link-local/multicast and IPv4 link-local
   candidates (keeps loopback for local testing), reducing first-connect
   connectivity-check timeouts. STUN/TURN configurability and client-side
   candidate handling (mDNS `.local` timeouts) still pending in the frontend.
6. **Ops polish** — quiet the RTMP relay teardown errors on reconnect.

## Open questions

- WebRTC playback URL lifetime/rotation model (mirror HLS tokens).
- Whether to keep HLS as the primary path with WebRTC as an enhancement, or vice
  versa.
- STUN/TURN deployment for non-local viewers behind restrictive NATs.
