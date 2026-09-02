# zer0-stream

Streaming backend for zer0.tv — live ingest, media processing, and playback
delivery. This project is intentionally separate from the discovery application
and owns live ingest, session state, and playback delivery.

## Components

| Component | Directory | Role | Default ports |
|---|---|---|---|
| **media_worker** | `media_worker/` | RTMP ingest + Membrane pipeline (HLS **and** WebRTC) | 1935 (RTMP), 8080 (HTTP) |
| **control plane** | `zer0_stream/` | Streaming API, sessions, playback tokens, lifecycle webhooks | 4000 |
| **chat** | `chat/` | Chat WebSocket service | 4100 |
| **frontend** | `twitch-elixir/` | zer0.tv web app / channel pages | 4000 |

## Current status

- **RTMP ingest + HLS playback**: working. OBS → RTMP → Membrane pipeline → HLS.
- **WebRTC playback**: implemented and validated on the internet-facing dev env,
  with a **TURN relay** (coturn on OPNsense) for NAT traversal.
- **LivePipeline mode** (`LIVE_PIPELINE_MODE=true`) runs a single Membrane pipeline
  that tees the stream to **both HLS and WebRTC** simultaneously (no more one-output
  limit). This is the production path.
- **Delivery toggle**: creators choose **Standard** (HLS) vs **Low latency** (WebRTC)
  in Creator Studio → **Viewer experience**.
- **HLS fallback**: WebRTC falls back to HLS automatically when it can't connect.
- **Viewer counts**: per-viewer tracking (token-derived viewer id + WebRTC/HLS
  coordination), so one person counts as one viewer.

## Docs

- [`STATUS.md`](STATUS.md) — current status of the stack
- [`plan.md`](plan.md) — architecture and rollout plan
- [`webrtc.md`](webrtc.md) — WebRTC implementation notes and status (shared-origin
  signaling, TURN config)
- [`ENV_VARS.md`](ENV_VARS.md) — per-component environment variables and the
  shared secrets that must match across services

## Scope

This repository is a separate service boundary. It does not share the zer0.tv
database schema or application deployment lifecycle.

## Planned / not yet built

- WHIP ingest support
- Object storage / recording for archived VOD
- CDN-backed HLS origin (currently served directly from the media worker)
