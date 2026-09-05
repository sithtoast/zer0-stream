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
- Signaling is served on the **shared HTTP origin** (`HLSRouter` on port 8080)
  at `/webrtc/<session_id>`, so it flows through the existing
  `stream.dev.zer0.tv` reverse proxy with no extra Caddy route or dynamic port.
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
| Signaling | Per-session WebSocket port | Shared origin `/webrtc/<session_id>`, URL via control plane |
| Auth | None | Signed WebRTC playback token |
| Player | Standalone test page | Integrated into channel page + HLS fallback |
| Packaging | Patched vendored Boombox (gitignored) | Tracked pipeline or Boombox fork |
| ICE | Default STUN, IPv6 noise | Filter IPv6, STUN/TURN configurable via env (`TURN_URL`/`TURN_SECRET`) |

## Production steps

1. **Tee-based pipeline** — build a tracked Membrane pipeline in `media_worker`
   that feeds both HLS and WebRTC from one RTMP source.

   **Status: implemented** in `media_worker/lib/zer0_media/live_pipeline.ex`
   (`Zer0Media.LivePipeline`). `BroadcastTee` sends the primary output to HLS
   and demand-limited secondary copies to each WebRTC viewer. Video timestamp
   scaling defaults to `1.0`; publisher-specific corrections are opt-in.

   Each viewer gets a separate `WebRTCBin`, signaling relay and temporary
   crash group. Its audio/video legs are linked after track negotiation and
   ICE/DTLS connection. A disconnect removes only that viewer's branch; the
   next connection creates a fresh branch. The registry maps session IDs to
   live pipelines and removes entries when their pipeline exits.

   `WebRTCBin` completes setup immediately so an unconnected peer cannot gate
   HLS. Each branch transcodes AAC to Opus and passes H.264 through, so audio
   encoding cost and outgoing bandwidth currently grow per viewer.
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

   **Internet-facing media reachability is still open.** Signaling now works
   through the shared origin, but the RTP/DTLS media path (ephemeral UDP ports,
   STUN-only) still needs to be exposed for remote viewers — either a fixed ICE
   port range forwarded through OPNsense, or a TURN relay.
6. **Ops polish** — quiet the RTMP relay teardown errors on reconnect.

## Open questions

- WebRTC playback URL lifetime/rotation model (mirror HLS tokens).
- Whether to keep HLS as the primary path with WebRTC as an enhancement, or vice
  versa.
- STUN/TURN deployment for non-local viewers behind restrictive NATs.

  **Status: implemented and validated.** The media worker builds STUN + TURN
  ICE servers from env and shares them with the browser via the control plane
  playback response. coturn runs on the OPNsense box with `use-auth-secret`
  (external IP + non-zero quotas), and OPNsense forwards UDP 3478 and the relay
  range 49152-65535.

  **TURN config is split** between the server side and the browser:
  - `TURN_URL` — used by the WebRTC sink (server side). Point at the LAN address
    (e.g. `turn:192.168.1.1:3478?transport=udp`) when the media worker is on the
    same network as coturn, to avoid NAT reflection.
  - `TURN_PUBLIC_URL` — handed to the browser (e.g. `turn:199.193.114.34:3478?transport=udp`).
    Must be a public, reachable address. Defaults to `TURN_URL` if unset.
  - `TURN_SECRET` — coturn `static-auth-secret`; must match the Auth Secret set
    in the OPNsense coturn config.

  See `ENV_VARS.md` for the full per-component environment reference.
