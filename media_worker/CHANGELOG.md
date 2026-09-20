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

LL-HLS is not connected to production ingest or HTTP playback in this slice.
No release artifact, deployment or playback-default change is included.
