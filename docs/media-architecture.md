# Media architecture and opt-in LL-HLS origin

Updated 2026-09-19. Baseline: `67af6f9`. This document describes current code
and separates implemented foundations from deployment plans. `plan.md` remains
the historical product plan; no prior ADR directory/convention exists.

## Current baseline

```text
RTMP publisher -> isolated RTMP client -> LivePipeline
                                         |-- H.264/AAC -> CMAF -> standard HLS files -> viewers
                                         |                 `-- opt-in LL-HLS origin -> viewers
                                         `-- per-viewer WebRTC branch -> interactive viewers

Phoenix control plane -> accounts / auth / stream metadata / sessions / API / orchestration
```

The worker stays separate from Phoenix/Ecto because its media/native dependency
graph and scaling needs differ. BEAM owns lifecycle, supervision, request waits
and coordination; Membrane and native libraries own codecs and CMAF muxing.
There is no measured reason here for a language rewrite.

| Area | Verified state and remaining work |
|---|---|
| Ingest | Vendored RTMP client isolation preserves the listener and healthy publishers after malformed traffic. RTMPClientHandler handles idle timeout, disconnect and session cleanup; pipeline monitoring now ends accounting and stops ingest on pipeline loss, including an LL-HLS origin failure. |
| Supervision | LivePipelineSupervisor starts temporary per-session Membrane supervisors. A publisher connection owns lifecycle; WebRTC outputs use separate temporary crash groups. RTMPServer is still started by the command/task, outside the application child list. |
| Packaging | Locked `membrane_http_adaptive_stream_plugin` **0.21.3**, `membrane_mp4_plugin` **0.36.10**. Separate audio/video CMAF, live mode, 20-second target window. Segment target remains 1 second by default; actual cuts depend on keyframes. |
| HTTP/storage | HLSRouter serves local files. The opt-in LLHLS.Storage adapter persists partial segments and /llhls serves authenticated blocking reload/preload waits. Default FileStorage still serves ordinary HLS. HLSCleanup purges stale session directories on startup and keeps ended sessions for 60 seconds by default. This is not archival storage. |
| Timing | Timestamp scale and AAC rate remain 1.0. New MediaConfig validates timing at application startup, accepts explicit milliseconds and converts through Membrane.Time. Old segment nanoseconds are a deprecated compatibility alias. |
| WebRTC | Separate peer/signaling/sink per viewer and demand-aware BroadcastTee outputs already fix the former single-peer limitation. AAC decoding and Opus encoding still happen per viewer. |
| Viewer identity | Verified v2 tokens preserve identity across token refresh and HLS/WebRTC switching. ViewerTracker deduplicates session/identity heartbeats with a TTL. Standard HLS still counts media requests and rewrites URLs with token and viewer_id. The opt-in LL-HLS session/heartbeat API uses shared media URLs and header/cookie authorization; its frontend and edge integration remain pending. |
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

Retain the installed CMAF primitives. `Zer0Media.LLHLS.Storage` implements the
existing callback contract: partial metadata `sequence_number` is the part index,
while completed-segment `sequence_number` is the MSN. Byte offsets and duration
sums are checked. LocalStore writes a temporary file, atomically links an immutable
object into place without overwriting it, then Stream publishes metadata. Media
bytes do not travel through origin/state mailboxes. Atomic visibility is provided;
this is not a disk-fsync or archival durability guarantee.

The installed muxer assembles full segments from its parts. Tests verify exact
byte equality with stored parts, AAC/H.264 decoding, DTS and keyframe boundaries.
The generated LL-HLS playlist is the sole authority under `/llhls`; upstream
manifests remain under `/hls` with low-latency tags removed for standard fallback.
Delta variants are deliberately not exposed. Distinct immutable objects avoid
growing byte-range resources. No new codec, BMFF muxer or large dependency was added.

## Implemented opt-in path

Enable with `LIVE_PIPELINE_MODE=true` and `LLHLS_ENABLED=true`; defaults and the
existing frontend remain unchanged. See [origin operation and HTTP contract](llhls-origin.md).

`Zer0Media.LLHLS.Playlist` is a pure per-rendition state machine. It tracks ordered
parts, completed segments, media sequence, evictions, finalization and request
availability. Integer nanoseconds retain media timing precision. Its renderer
produces shared relative URIs, PART/PART-INF/SERVER-CONTROL tags, optional preload
hints and a completed-segment fallback. The generic renderer defaults blocking/hints off. The integrated origin enables
them together with working reload and hinted-object HTTP handlers.

`Zer0Media.LLHLS.Stream` is a temporary GenServer with a monitored publisher.
Requests use OTP replies and server-owned timers, grouped by `{request_kind, msn, part}`;
one update renders once and wakes all satisfied targets. Callers are monitored,
timers/monitors are removed on every completion path, and stale timer messages
are harmless. Default capacity is 5,000 waiting calls per rendition. Capacity
limits retained waits, not an incoming HTTP flood; add edge/HTTP admission limits
when exposing it. Per-request process memory includes neither sockets nor TLS.

Application Registry and DynamicSupervisor discover each generation. A temporary
Generation supervisor owns an Origin and independent temporary Stream children
for audio/video. The separately supervised LivePipeline and Origin monitor each
other. Origin fails the unit if any live rendition disappears; no state restarts
at MSN zero under the same URL. RTMPClientHandler monitors the pipeline, stops
ingest demand and ends session/viewer accounting on its loss. Other publishers
and WebRTC peer isolation remain independent. ABR coordination belongs above
these per-rendition processes, with aligned boundaries and eventual reports.

The owner must drain the muxer and complete the final segment before `finish/1`
adds ENDLIST. An unfinished segment is rejected. Publisher loss instead drains
waiters with an error and stops the incarnation; it does not invent a complete
segment or claim a finalized playable stream. A replacement starts with new
processes and generation-qualified URLs. Finalized state can serve its cached
playlist for one retention interval; then playlists stop serving while objects
remain for another interval before the generation supervisor is removed.

The behavioral reference is Apple's
[HTTP Live Streaming 2nd Edition draft 22](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/22/),
particularly sections 4.4.3.8, 4.4.4.9, 4.4.5.3 and 6.2.5.2. It remains a draft,
not a published replacement RFC. Tests cover old/available/future requests,
part-index rollover, sequence advancement and termination. Limits use the
advertised part/segment targets; waits default to three target durations.

The state model currently requires a whole-second target and rejects segment
duration beyond it. The production packager's segment setting is a **minimum**
cut duration, not an advertised maximum: the adapter uses a separately configured
fixed target (6 seconds by default), above the segment minimum and large enough
for the ingest GOP/sample boundaries. Parts exceeding it fail the generation;
operators must match this contract to publishers. Do not pass an arbitrary
millisecond minimum straight through as TARGETDURATION. There are no gaps,
discontinuities, in-generation init changes, delta updates, ABR variants or
rendition reports yet. The existing separate audio/video master is rewritten to
the generated rendition paths; a codec/header change requires a new generation. Parts remain in metadata until parent eviction; reducing their tag
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
compatibility. Those are goals; end-to-end latency has not been measured for this origin.

| Resource | Current treatment and eventual edge contract |
|---|---|
| Master playlist | Shared within a generation; currently private, no-store. Consider a bounded TTL only after edge authorization tests. |
| Media playlist | Dynamic, shared per rendition, private, no-store. Configure blocking-response caching only after proxy tests. Keep `_HLS_msn` and `_HLS_part` in cache keys and forward them to origin. Never collapse different targets to one cached answer. |
| Completed segment / part / init | Immutable once published, generation-qualified shared keys; private, max-age=3600, immutable. Public cacheability only behind a working edge authorization boundary. Retain origin objects for lagging clients beyond manifest eviction. |
| Hinted part | Origin waits until the whole part is available, then serves at full speed. No placeholder file or partial transfer masquerading as a completed part. |
| Playback authorization / heartbeat | Viewer-specific, authenticated and `private, no-store`; never embedded in media-object names. |
| Worker control/reporting endpoints | Origin/internal only; retain existing service authentication. |

The new session endpoint exchanges an existing signed playback token in the
Authorization header for a path-scoped HttpOnly cookie and a generation master
URL. Every LL-HLS resource verifies a header or cookie credential, including a
second expiration check after waiting. Media URLs carry no viewer identity;
only session creation/explicit heartbeats update ViewerTracker. Standard HLS
retains its existing token behavior. Frontend heartbeat lifecycle, Safari cookie
behavior and CDN edge authorization still require integration tests. Shared URLs
do not yet imply shared CDN caching. CDN hits must remain authorized.

Malformed delivery directives map to 400; unavailable/time-limited waits to 503;
unknown generations/objects to 404. Errors are private, no-store. Ended playlists
ignore delivery directives. Hinted-object waits only target the exact next part:
an unmaterialized hint returns 404 on segment rollover, not the next segment's
part under the wrong immutable URL. No busy polling is used.

Storage APIs should separate immutable object publication/read from retention and
playlist state. Current implementation uses local atomic publication via LocalStore and local
file reads in Router; a remote backend must replace both read and write sides.
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
Docker; this opt-in origin slice does not require a container migration.

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
| `:storage` | elapsed native time, payload bytes; callback type and success |
| `:generation_failed` | count |

Convert native timer measurements with `System.convert_time_unit/3`. These
publication counters record accepted metadata, not generated CMAF bytes. No
credentials/viewer IDs enter events. Active measurements are per process, not
global gauges; aggregate wait start/stop deltas. Storage duration includes disk publication and state acknowledgment, not capture-to-publication lag.
Ingest/egress bytes, CPU and broader pipeline metrics remain follow-ups.

From `media_worker/`:

```sh
HLS_HTTP_PORT=0 mix test
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted lib/zer0_media/llhls/*.ex test/llhls*test.exs
MIX_ENV=test mix run --no-start bench/llhls_waiters.exs
```

Validation for this slice: **91 passed** (one doctest, 90 tests), touched-file
format checks and application compilation with warnings as errors. Existing
vendored RTMP warnings and support-file discovery warnings remain. Generated
LL-HLS and fallback playlists parse with the installed ExM3U8 parser.

A checked-in synthetic six-second AAC/H.264 fixture runs through production
LivePipeline and the actual CMAF muxer. Tests verify part/segment byte equality,
ordered timestamps, 180 video frames, independent GOP starts, graceful ENDLIST
and ffprobe decoding both local media and the authenticated HTTP master. HTTP
regressions cover a real Bandit blocking request, preload publication, malformed
requests, timeout cleanup, authentication/CORS, heartbeat isolation, publisher
loss/reconnect, rendition loss and delayed object retirement.

The benchmark runs 100/1,000/5,000 separate BEAM callers, publication fanout,
timeout cleanup, process memory, server mailbox snapshots and playlist rendering.
See [recorded local results](llhls-benchmark.md). This does not measure HTTP/TLS
load, CDN request coalescing, network throughput or glass-to-glass latency. Caller
process death cleanup is tested; HTTP/1 disconnect may not immediately kill a
blocked Plug process, so its server-owned deadline bounds retention. Full socket
cancellation, HTTP/2 reset and churn behavior require network load testing.

Next slice: frontend session/heartbeat and opt-in Safari/hls.js playback against
real RTMP/OBS (including B-frames and changing GOPs), then proxy/cache tests and
sustained retention/churn measurements. Keep LL-HLS opt-in until these pass.
Apple validator and browser interoperability have not been claimed here.
