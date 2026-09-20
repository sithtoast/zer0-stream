# Media architecture and LL-HLS foundation

Updated 2026-09-19. Baseline: `67af6f9`. This document describes current code
and separates implemented foundations from deployment plans. `plan.md` remains
the historical product plan; no prior ADR directory/convention exists.

## Current baseline

```text
RTMP publisher -> isolated RTMP client -> LivePipeline
                                         |-- H.264/AAC -> CMAF/HLS files -> HLSRouter -> viewers
                                         `-- per-viewer WebRTC branch -> interactive viewers

Phoenix control plane -> accounts / auth / stream metadata / sessions / API / orchestration
```

The worker stays separate from Phoenix/Ecto because its media/native dependency
graph and scaling needs differ. BEAM owns lifecycle, supervision, request waits
and coordination; Membrane and native libraries own codecs and CMAF muxing.
There is no measured reason here for a language rewrite.

| Area | Verified state and remaining work |
|---|---|
| Ingest | Vendored RTMP client isolation preserves the listener and healthy publishers after malformed traffic. RTMPClientHandler handles idle timeout, disconnect and session cleanup; it does not yet monitor pipeline loss. Generation ownership must close that lifecycle gap. |
| Supervision | LivePipelineSupervisor starts temporary per-session Membrane supervisors. A publisher connection owns lifecycle; WebRTC outputs use separate temporary crash groups. RTMPServer is still started by the command/task, outside the application child list. |
| Packaging | Locked `membrane_http_adaptive_stream_plugin` **0.21.3**, `membrane_mp4_plugin` **0.36.10**. Separate audio/video CMAF, live mode, 20-second target window. Segment target remains 1 second by default; actual cuts depend on keyframes. |
| HTTP/storage | HLSRouter serves local files. No blocking reload or preload wait. FileStorage deliberately drops partial segments. HLSCleanup purges stale session directories on startup and keeps ended sessions for 60 seconds by default. This is not archival storage. |
| Timing | Timestamp scale and AAC rate remain 1.0. New MediaConfig validates timing at application startup, accepts explicit milliseconds and converts through Membrane.Time. Old segment nanoseconds are a deprecated compatibility alias. |
| WebRTC | Separate peer/signaling/sink per viewer and demand-aware BroadcastTee outputs already fix the former single-peer limitation. AAC decoding and Opus encoding still happen per viewer. |
| Viewer identity | Verified v2 tokens preserve identity across token refresh and HLS/WebRTC switching. ViewerTracker deduplicates session/identity heartbeats with a TTL. HLS still counts media requests and rewrites URLs with token and viewer_id; this is not CDN-ready accounting. |
| Legacy | LivePipeline is the documented production path but still requires `LIVE_PIPELINE_MODE=true`. Unset means Boombox. `LEGACY_HLS_MODE=true` actually bypasses Boombox when LivePipeline is off, optionally relaying to BOOMBOX_RELAY_URL. Preserve this behavior until a mode migration accounts for relay users. LivePipeline now skips the unnecessary Boombox prewarm. |
| Containers | Worker has a multi-stage build, locked dependencies, preserved vendored fixes and `mix run --no-compile --no-deps-check`. It still includes Mix/source and runs as root. Phoenix still runs `mix phx.server`. Neither is an OTP-release runtime yet. |

Earlier fixes are retained: RTMP isolation, ExICE TURN routing, per-viewer
signaling/crash groups, nonblocking secondary media branches, timestamp defaults,
viewer identity and Docker native-build integrity. No frontend/player changes,
codec changes, public deployment, or default playback switch accompany this slice.

## Decision: reuse CMAF packaging; own the origin contract

Checked the published ecosystem on 2026-09-19:

- [HTTP adaptive stream plugin](https://hex.pm/packages/membrane_http_adaptive_stream_plugin)
  lists 0.21.3, matching the lockfile. Its installed SinkBin accepts
  `partial_segment_duration`; the storage callback provides duration, sequence,
  independence, partial name and byte offset. Its serializer already emits
  LL-HLS tags. FileStorage is the explicit missing partial-storage boundary.
- [membrane_hls_plugin](https://hex.pm/packages/membrane_hls_plugin) lists 3.0.10.
  Its [SinkBin API](https://hexdocs.pm/membrane_hls_plugin/Membrane.HLS.SinkBin.html)
  has different storage/synchronization contracts and no documented partial
  duration option. It does not currently justify replacing our production path.

Retain the installed CMAF primitives. The next adapter should atomically store
complete fragments and then publish their metadata to Zer0Media.LLHLS.Stream.
Start with a small implementation of the existing storage callbacks, configured
naming functions and a single authority for the served media playlist. Do not
serve competing upstream/generated manifests at the same URI. Verify the
callback ordering and completed-segment assembly with real muxer fixtures before
turning it on. The foundation uses distinct part objects, not growing byte ranges.
If the sink contract proves inadequate, reuse its CMAF muxer under a small sink;
there is no current justification for a fork or a new codec/BMFF implementation.

## Implemented foundation (not connected to playback yet)

`Zer0Media.LLHLS.Playlist` is a pure per-rendition state machine. It tracks ordered
parts, completed segments, media sequence, evictions, finalization and request
availability. Integer nanoseconds retain media timing precision. Its renderer
produces shared relative URIs, PART/PART-INF/SERVER-CONTROL tags, optional preload
hints and a completed-segment fallback. Blocking/hints are opt-in and default off:
only advertise them once the corresponding HTTP handlers work.

`Zer0Media.LLHLS.Stream` is a temporary GenServer with a monitored publisher.
Requests use OTP replies and server-owned timers, grouped by `{msn, part}`;
one update renders once and wakes all satisfied targets. Callers are monitored,
timers/monitors are removed on every completion path, and stale timer messages
are harmless. Default capacity is 5,000 waiting calls per rendition. Capacity
limits retained waits, not an incoming HTTP flood; add edge/HTTP admission limits
when exposing it. Per-request process memory includes neither sockets nor TLS.

The modules are dormant until explicitly started. They are not yet registered
in the application's production supervision tree or used by HLSRouter. The next
integration should give each publisher generation a supervisor owning pipeline
and rendition states. Pipeline/origin failure must end that generation as a unit;
never restart a zero-sequence state under an old immutable media URL. Each
rendition gets an independent process; ABR coordination belongs above these
processes, with aligned boundaries and eventual rendition reports.

The owner must drain the muxer and complete the final segment before `finish/1`
adds ENDLIST. An unfinished segment is rejected. Publisher loss instead drains
waiters with an error and stops the incarnation; it does not invent a complete
segment or claim a finalized playable stream. A replacement starts with new
processes and generation-qualified URLs. Finalized state can serve its cached
playlist until the future lifecycle supervisor's retention grace expires.

The behavioral reference is Apple's
[HTTP Live Streaming 2nd Edition draft 22](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/22/),
particularly sections 4.4.3.8, 4.4.4.9, 4.4.5.3 and 6.2.5.2. It remains a draft,
not a published replacement RFC. Tests cover old/available/future requests,
part-index rollover, sequence advancement and termination. Limits use the
advertised part/segment targets; waits default to three target durations.

The state model currently requires a whole-second target and rejects segment
duration beyond it. The production packager's segment setting is a **minimum**
cut duration, not an advertised maximum: the adapter must establish an adequate
fixed target from the ingest/keyframe contract, accommodate rounding/sample
boundaries, and validate that contract with real media. Do not pass an arbitrary
millisecond minimum straight through as TARGETDURATION. There are no gaps,
discontinuities, init changes, delta updates, multivariant generation or rendition
reports yet. Parts remain in metadata until parent eviction; reducing their tag
window to the recommended age is still an integration refinement. Pathological
state is capped at 1,024 parts per segment and 1,024 retained segments; normal
windows retain six segments, extending as needed to preserve minimum duration.

## Target delivery and cache boundaries

```text
Publisher -> Media worker -> CMAF/LL-HLS origin -> reverse proxy/CDN -> broadcast viewers
                   `------------------------------------ WebRTC -> interactive viewers
Phoenix control plane -> auth / accounts / stream metadata / sessions / API / orchestration
```

LL-HLS should become the normal broadcast path, targeting measured 2–4 second
end-to-end latency. WebRTC remains optional for interaction, with standard HLS
compatibility. Those are goals, not latency achieved by this foundation.

| Resource | Planned treatment |
|---|---|
| Master playlist | Shared, bounded short TTL; generation/rendition changes invalidate it. |
| Media playlist | Dynamic, shared per rendition. Begin conservatively with revalidation; configure blocking-response caching only after proxy tests. Keep `_HLS_msn` and `_HLS_part` in cache keys and forward them to origin. Never collapse different targets to one cached answer. |
| Completed segment / part / init | Immutable once published, generation-qualified shared keys. Public cacheability only behind a working authorization boundary. Retain origin objects for lagging clients beyond manifest eviction. |
| Hinted part | Origin waits until the whole part is available, then serves at full speed. No placeholder file or partial transfer masquerading as a completed part. |
| Playback authorization / heartbeat | Viewer-specific, authenticated and `private, no-store`; never embedded in media-object names. |
| Worker control/reporting endpoints | Origin/internal only; retain existing service authentication. |

Do not simply remove current URL tokens or mark existing personalized responses
public. A subsequent slice must provide a session/heartbeat API and frontend
heartbeat lifecycle, then move media authorization to a tested edge credential
or cookie/header mechanism with Safari/CORS support. CDN cache hits must still
be authorized. Only then remove per-viewer URL rewriting. Edge request telemetry
can supplement counts later; origin segment hits will undercount cached viewers.
For blocking HTTP integration map malformed directives to 400, unavailable waits
to 503, and unknown generations/objects to 404, with explicit error cache policy.

Storage APIs should separate immutable object publication/read from retention and
playlist state. Start with local atomic temporary-file/rename publication.
Hot in-memory parts, shared disks and object-backed storage can later implement
the same contract without moving large media binaries into the stream mailbox.
Evicted metadata is a scheduling signal, not immediate delete permission.
Retain parts beyond tag removal and keep segment availability long enough for
previous playlists. Init objects must outlive all referencing segments. Archive
storage is separate from the hot-part path; no S3 migration is needed now.

## WebRTC, ABR and deployment follow-ups

Shared encoded Opus is compatible with the WebRTCBin input contract; its RTP
payloader and peer state are already per viewer. A safe implementation still
needs a continuously driven, separately isolated AAC->Opus branch, cached stream
format for late joiners, and recovery/slow-viewer tests. Putting shared encoding
on HLS's primary demand path would regress isolation. Keep the existing branches
until that media integration is exercised; this slice makes no CPU savings claim.

ABR should add configurable rendition descriptors and aligned encoders upstream
of these per-rendition origins. Encoder workers can be local, native/FFmpeg,
hardware or remote. The Phoenix app remains orchestration, not a video encoder.

Move the worker to an OTP release after making RTMP a supervised application
child and defining the explicit legacy subprocess contract. Build a release in
a builder stage; keep native runtime libraries, drop compiler/Mix/source, run as
non-root and make media/cache directories explicitly writable. Preserve locked
vendored dependencies. The remaining Boombox runtime needs its own release or an
explicit legacy image. Test Linux startup, RTMP and native loading before changing
Docker; this state-only slice does not require a container migration.

## Observability and validation

Events under `[:zer0_media, :llhls, event]`:

| Event | Measurements / metadata |
|---|---|
| `:part`, `:segment` | count, media duration (nanoseconds); segment eviction count |
| `:render` | elapsed native time, playlist bytes |
| `:wait_start` | count and active waits in this process |
| `:wait_stop` | count, active waits, elapsed native time; outcome (`:published`, `:timeout`, `:cancelled`, `:publisher_down`, `:terminated`) |
| `:rejected` | count; capacity reason |
| `:publisher_down` | count |

Convert native timer measurements with `System.convert_time_unit/3`. These
publication counters record accepted metadata, not generated CMAF bytes. No
credentials/viewer IDs enter events. Active measurements are per process, not
global gauges; aggregate wait start/stop deltas. Part generation/publication lag,
ingest/egress bytes and pipeline resource metrics need the real adapter.

From `media_worker/`:

```sh
HLS_HTTP_PORT=0 mix test
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted lib/zer0_media/llhls/*.ex test/llhls*test.exs
MIX_ENV=test mix run --no-start bench/llhls_waiters.exs
```

Validation for this slice: **69 passed** (one doctest, 68 tests), touched-file
format checks and forced application compilation with warnings as errors. Existing
vendored RTMP warnings and the existing support-file discovery warning remain.
Generated LL-HLS and fallback playlists also parse with the installed ExM3U8 parser.

The benchmark runs 100/1,000/5,000 separate BEAM callers, publication fanout,
timeout cleanup, process memory, server mailbox snapshots and playlist rendering.
See [recorded local results](llhls-benchmark.md). It does not measure HTTP/TLS,
CDN request coalescing, network throughput or glass-to-glass latency. Tests are
metadata/state tests and existing media regressions, not Apple validator or
Safari/hls.js interoperability evidence.

Next slice: atomically persist real CMAF parts; integrate generation/rendition
ownership with publisher lifecycle; expose authenticated blocking playlist and
hinted-object handlers together. Validate AAC/H.264 fragment timestamps and
keyframe boundaries before browser playback. Then exercise Safari/hls.js, proxy
cache behavior, disconnect/reconnect and long-running storage retention. Keep
LL-HLS opt-in until these pass; do not advertise it solely because tags render.
