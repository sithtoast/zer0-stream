# zer0-stream — Status

Living status of the streaming stack and frontend. Update this as things change.
Last updated: 2026-09-02.

## High-level

The stack ingests RTMP and delivers **both HLS and WebRTC** from a single
Membrane pipeline (LivePipeline mode). WebRTC is validated on the internet-facing
dev environment with a TURN relay. Creators choose delivery mode per channel.

## Component status

| Component | Directory | Status | Notes |
|---|---|---|---|
| **media_worker** | `media_worker/` | ✅ Working | RTMP ingest + Membrane pipeline (HLS + WebRTC). LivePipeline is the production path. |
| **control plane** | `zer0_stream/` | ✅ Working | Streaming API, sessions, playback tokens, lifecycle webhooks. |
| **chat** | `chat/` | ⚠️ Needs config alignment | WebSocket chat service; requires matching `CHAT_TOKEN_SECRET`, reachable `CHAT_SOCKET_URL`, and `CHAT_ALLOWED_ORIGINS`. |
| **frontend** | `twitch-elixir/` | ✅ Working | Channel pages, WebRTC player with HLS fallback, Delivery toggle. |

## Feature status

### Implemented & validated

- **RTMP ingest** — OBS → RTMP → media_worker. Working.
- **HLS playback** — served by the media worker at `/hls/...`, token-protected.
- **WebRTC playback** — sub-second latency, validated on the internet-facing dev
  env. Signaling on the shared origin (`/webrtc/<session_id>`), TURN relay for NAT.
- **LivePipeline mode** — single pipeline tees to HLS + WebRTC simultaneously.
- **Delivery toggle** — Creator Studio → **Viewer experience**: Standard (HLS) /
  Low latency (WebRTC).
- **HLS fallback** — WebRTC falls back to HLS automatically when it can't connect.
- **Viewer counts** — accurate per viewer (token-derived viewer id + WebRTC/HLS
  stand-down coordination).
- **Playback token protection** — HLS manifests/segments require a signed token.

### Partially done

- **TURN / NAT traversal** — coturn on OPNsense with `use-auth-secret`, external
  IP, and non-zero quotas. UDP relay works; TURN-over-TLS not yet enabled.
- **Chat** — implemented; needs the four config items aligned to connect
  (see `ENV_VARS.md` troubleshooting).

### Not yet built / planned

- **WHIP ingest** support.
- **VOD / recording** to object storage.
- **CDN-backed HLS origin** (currently served directly from the media worker).
- **Multi-viewer WebRTC scaling** — current WebRTC sink serves one peer per
  session; large WebRTC audiences need an SFU or per-viewer sinks.
- **TURN-over-TLS** on port 5349.

## Known issues / caveats

- **HLS latency** — ~5s (up to ~8-9s on some setups) is expected for standard HLS.
  WebRTC is the low-latency path. OBS keyframe interval should be 1-2s.
- **LivePipeline HLS path** — `/hls/` (token-protected); Boombox legacy path is
  `/hls-boombox/`. The control plane picks the path based on whether WebRTC is
  active.
- **WebRTC single-peer** — one WebRTC sink per session; fine for small audiences.
- **Third-party cookie / cross-origin** — viewer attribution now uses the playback
  token, so it's robust to cross-origin cookie blocking.

## How to run (dev)

- **Control plane**: `cd zer0_stream && mix phx.server`
- **Media worker** (LivePipeline + WebRTC): see `media_worker/README.md` — set
  `LIVE_PIPELINE_MODE=true` plus the WebRTC/TURN env vars.
- **Chat**: `cd chat && mix setup && mix phx.server`
- **Frontend**: `cd twitch-elixir && mix phx.server`

## Docs

- [`README.md`](README.md) — overview
- [`plan.md`](plan.md) — architecture / rollout plan (historical)
- [`webrtc.md`](webrtc.md) — WebRTC implementation notes & TURN config
- [`ENV_VARS.md`](ENV_VARS.md) — per-component env vars & shared secrets
