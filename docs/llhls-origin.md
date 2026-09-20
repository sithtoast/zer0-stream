# Experimental LL-HLS origin

The existing LivePipeline can now produce and serve real CMAF partial segments.
This remains opt-in. The companion frontend now offers an explicit experimental LL-HLS choice; no
public server, proxy or deployment has been changed by this implementation.

## Portainer testing stack

`Publish LL-HLS Testing Images` builds the API and worker on pushes to
`codex/llhls-foundation`. It publishes `llhls-foundation` and immutable
`llhls-<full commit SHA>` tags. It never publishes `latest` or calls a deployment
webhook. The existing production publishing workflows are separate; do not
manually dispatch them to deploy this branch.

Use `zer0_stream/docker-compose.llhls-testing.yml` for `zer0-stream-testing`.
For a Git-managed stack use repository `https://github.com/sithtoast/zer0-stream`,
reference `refs/heads/codex/llhls-foundation`, and that Compose path. For an
existing editor-managed stack, paste the same file into its editor and preserve
its environment values. Wait for both images to build before redeploying and
select **Re-pull image**; pin `LLHLS_IMAGE_TAG=llhls-<full commit SHA>` when desired.

This file explicitly enables all three opt-ins (`LIVE_PIPELINE_MODE`,
`LLHLS_ENABLED`, `LLHLS_PLAYBACK_ENABLED`) plus the timing/retention limits below.
It is specific to the existing test macvlan network `dc`, preserving API `.7`,
chat `.8`, and worker `.9` on `192.168.1.0/24`. It uses those explicit addresses
for service calls because production shares this network and service aliases.
Existing test database and signing secrets remain Portainer environment values.
Chat is pinned to its pre-LL-HLS image; updating it is a separate operation.
The worker's internal/public TURN endpoints and WebRTC URL are preserved.

Keep `PLAYBACK_BASE_URL=https://stream.dev.zer0.tv`,
`HLS_ALLOWED_ORIGINS=https://dev.zer0.tv`, and the matching frontend backend
configuration. The proxy must route `/llhls` to the worker, preserve authorization
and delivery query parameters, and support the blocking timeouts below. A branch
reference alone does not enable LL-HLS and production Compose still uses `latest`.
The companion `codex/llhls-frontend` frontend must also be deployed to expose the
experimental playback choice. A healthy idle worker is not a live OBS acceptance
result; verify an actual publisher and player after rollout.

## Enable on a test worker

Set these variables before starting the worker through its existing entry point:

```sh
LIVE_PIPELINE_MODE=true
LLHLS_ENABLED=true
HLS_SEGMENT_DURATION_MS=1000
LLHLS_PART_DURATION_MS=200
LLHLS_TARGET_DURATION_MS=6000
LLHLS_RETENTION_MS=60000
LLHLS_MAX_WAITERS=5000
```

The segment setting is Membrane's minimum cut duration. The separately advertised
6-second maximum accommodates a fixed 1–2-second GOP plus sample boundaries;
actual segments must remain within that maximum. Parts must be at least 50ms
and no longer than the segment minimum. The target must be a whole second above
the minimum; retention must be at least eight target durations. Startup rejects
invalid settings. Exceeding duration/order limits or changing codec headers
fails that generation; publisher reconnect creates new immutable URLs.

Set `HLS_ALLOWED_ORIGINS` to the player origins and use the existing shared
`PLAYBACK_TOKEN_SECRET`. HTTPS is required for the default Secure session cookie.
The worker's existing HTTP listener also serves `/llhls`. Tests use temporary
listeners on port zero and never restart an existing service.

LL-HLS objects default to `priv/llhls/stream-session-ID/GENERATION/RENDITION/`.
Application setting `:zer0_media, :llhls_dir` can choose a different writable root.
The legacy fallback output still lives in its original HLS directory. This
initial local adapter duplicates full fallback segments and LL-HLS segments in
addition to parts; account for that disk cost before enabling many publishers.
Startup removes stale session directories. Storage is ephemeral, not an archive.

## Session, media and heartbeat contract

| Request | Credential | Result |
|---|---|---|
| `POST /llhls/ID/session` | `Authorization: Bearer TOKEN` | Wait-free readiness check; 200 sets a scoped HttpOnly cookie and returns `url` and `heartbeat_url`; 503 until both tracks and the master exist. |
| `POST /llhls/ID/heartbeat` | Bearer or session cookie | 204 refreshes ViewerTracker identity from the signed token; 410 once the publisher has ended. |
| `GET /llhls/ID/GENERATION/master.m3u8` | Bearer or session cookie | Shared relative audio/video playlist URLs. |
| `GET /llhls/ID/GENERATION/RENDITION/index.m3u8` | Bearer or session cookie | Full dynamic playlist, optionally with `_HLS_msn` and `_HLS_part`. |
| `GET /llhls/ID/GENERATION/RENDITION/part-MSN-INDEX.m4s` | Bearer or session cookie | Immutable complete part; waits only if this is the exact next hinted object. |
| `GET /llhls/ID/GENERATION/RENDITION/segment-MSN.m4s` or `init.mp4` | Bearer or session cookie | Immutable completed segment or initialization object. |

An existing control-plane signed playback token authorizes the session ID. Query
string tokens are not supported on `/llhls`; they remain supported by the existing
standard HLS routes. Media/playlist requests do not refresh viewer accounting.
The frontend explicitly heartbeats every 20 seconds while playing and renews
its credential before expiry. Expired credentials are
rejected even if a request was already blocked when the token expired.

The signed control-plane playback API adds `llhls: {session_url, token, expires_at}`
when `LLHLS_PLAYBACK_ENABLED=true` and the session uses LivePipeline. The frontend
uses this descriptor to show the experimental choice. Automatic stays the default;
selecting LL-HLS suppresses WebRTC probing for that selection. The frontend prefers
hls.js where MediaSource is supported, retaining native HLS otherwise.

For a direct browser experiment, exchange the token with `fetch` using
`credentials: "include"`, then load the returned master with cookies enabled on
all playlist/object requests. The cookie uses `SameSite=None; Secure; HttpOnly`
and path `/llhls/ID/`. A same-site proxy is preferable for Safari experiments;
third-party cookie behavior has not been validated. For local HTTP-only tests,
application setting `:llhls_cookie_secure` can be false (then SameSite=Lax).
This setting is deliberately not a production environment default.

A header-capable player/debugger can instead send the Bearer header on **every**
request. Do not put tokens in media URLs. A future edge may authorize requests
before looking up shared cache objects; that behavior is not implemented here.

## Blocking and caching

The media playlist advertises CAN-BLOCK-RELOAD, PART-HOLD-BACK (three part targets)
and PRELOAD-HINT. Requests wait through monitored OTP calls, never polling.
Playlist and part waits share the per-rendition capacity bound. Default deadlines
are three segment targets (18 seconds with the defaults). Known available/old
playlist targets return immediately. Initial playlists wait for first media.

Malformed, duplicate or excessive delivery directives return 400. Capacity,
timeout and unavailable origins return 503. Unknown generations/objects return
404. Part directives require an MSN. Ended playlists ignore delivery directives.
A hint that disappears at segment rollover returns 404; it cannot return bytes
belonging to a different URI. Guessing arbitrary future object names does not
allocate waiters.

All playlists, session responses, heartbeats and errors use
`Cache-Control: private, no-store`. Immutable parts, segments and init objects
use `private, max-age=3600, immutable`. Shared URLs enable later CDN integration,
but private cache policy intentionally prevents a CDN from bypassing viewer
credentials. A future proxy must preserve delivery directives in its cache key,
forward them to origin and keep blocking request deadlines long enough.

Waiter process death removes timers/monitors. An HTTP/1 socket disconnect may not
immediately kill a blocked Plug process; the bounded deadline remains the cleanup
backstop. Tests do not yet establish network cancellation under HTTP/2 resets,
large socket churn or proxy coalescing. Set HTTP/edge admission limits before
exposing this experimental path widely; the waiter cap is not a rate limiter.

## Lifecycle and retention

Each publisher incarnation receives a random generation ID and independent
rendition states. Pipeline, origin or live rendition loss fails the generation
and releases pending callers. The RTMP handler stops demand and session/viewer
accounting on pipeline loss. Reconnect does not reuse sequence-zero object URLs.

Metadata window eviction schedules object removal after the retention grace;
files referenced by a recently served playlist remain readable. Minimum retention
covers the maximum six-segment window plus segment duration with margin. Completed
streams expose ENDLIST only after the muxer completes every final segment. They
serve final playlists for one grace interval, then stop serving playlists and
retain objects for one more interval before removing the generation. Unexpected
publisher loss fails pending requests instead of fabricating ENDLIST.

Codec/header changes require a new generation. Discontinuities, delta playlists,
ABR encoders and rendition reports are not implemented. Audio and video already
have separate states; future aligned encoder renditions can extend that boundary.

## Verified and next

The full media-worker suite passes: 91 checks including existing RTMP/WebRTC
regressions. A checked-in synthetic AAC/H.264 fixture goes through the production
LivePipeline and installed Membrane CMAF muxer. With ffprobe installed, the test
verifies 180 video frames, AAC decoding, DTS ordering, independent GOP starts and
actual authenticated HTTP master playback. Part bytes exactly assemble into their
completed segment. The network blocking test runs through a real Bandit listener.

These are local integration results, not live OBS, B-frame, browser, Apple
validator or CDN acceptance. Frontend session/heartbeat integration, renewal, mode switching and fallback
are now implemented in the companion frontend. Its local Chromium hook fixture
decoded real CMAF using hls.js and discovered 29 parts. Native Safari, live OBS
and end-to-end latency remain unverified. Next, test live ingest with a visible
clock, then proxy behavior, sustained storage and socket churn.
The 2–4-second end-to-end target remains unmeasured.

See [architecture](media-architecture.md), [synthetic waiter results](llhls-benchmark.md)
and [fixture provenance](../media_worker/test/fixtures/llhls/README.md).
