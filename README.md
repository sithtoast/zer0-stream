# zer0-stream

Streaming backend for zer0.tv. This project is intentionally separate from the discovery application and is designed to own live ingest, media processing, and playback delivery.

## Goals

- Accept RTMP ingest from OBS and other publishing tools
- Add WHIP support after the initial RTMP pipeline is stable
- Transcode and package streams with Membrane
- Deliver low-latency HLS through an origin/CDN model
- Expose a small, signed API contract to the zer0.tv app

## Scope

This repository is a new service boundary. It should not share the existing zer0.tv database schema or application deployment lifecycle.

## Planned architecture

- Separate repository and deployment pipeline
- Membrane as the media pipeline framework
- PostgreSQL for streaming metadata and auth state
- Object storage for recorded segments/manifests or origin assets
- CDN-backed HLS playback
- Signed tokens for ingest and playback authorization

## Documents

- plan.md — architecture and rollout plan

## Notes

This is a planning scaffold. The project will be expanded as the live-streaming backend is implemented.
