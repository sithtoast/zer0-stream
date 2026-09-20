# Media worker changelog

## Unreleased

- Validate explicit millisecond segment/part timing at startup; preserve the old
  nanosecond segment variable as a deprecated compatibility alias.
- Skip the unused Boombox prewarm when starting LivePipeline mode.
- Add a pure per-rendition LL-HLS publication model, playlist renderer and a
  temporary OTP coordinator with grouped, monitored, bounded waiting requests.
- Test sequence/part transitions, expiration, timeout/cancellation, publisher
  failure and restart; add a 100/1,000/5,000-caller benchmark and Telemetry events.
- Refresh media architecture and correct outdated single-peer/legacy-mode docs.

- Add opt-in real CMAF part storage using the existing Membrane muxer, atomic
  immutable objects, generation lifecycle and delayed retirement.
- Serve authenticated blocking playlists and hinted parts under `/llhls`, with
  shared media URLs, session-cookie exchange and explicit viewer heartbeats.
- Monitor pipeline loss to stop RTMP demand and session accounting; preserve
  standard HLS fallback and isolated WebRTC outputs.
- Validate real AAC/H.264 fragments and authenticated HTTP master decoding, plus
  origin authorization, timeout, reconnect, failure and retention regressions.

- Add a loopback browser fixture using the real CMAF muxer, plus opt-in signed
  playback descriptors for the companion frontend integration.

LL-HLS requires explicit enablement; native Safari, live OBS and CDN acceptance
remain pending. Standard HLS and existing playback defaults are preserved.
No release artifact, deployment or playback-default change is included.
