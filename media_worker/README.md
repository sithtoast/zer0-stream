# zer0-media

Media worker for zer0-stream. This service owns the Membrane RTMP listener and
is intentionally separate from the Phoenix/Ecto control plane because its
dependency graph includes native media libraries.

## Local RTMP smoke test

Start the control plane first:

```sh
cd ../zer0_stream
mix phx.server
```

Create or rotate stream keys from the control-plane directory, not this media
worker directory:

```sh
cd ../zer0_stream
mix run priv/repo/seeds.exs
```

The seed script uses `Zer0Stream.Streams`, which is not part of this Mix app.

Then start this worker in a second terminal:

```sh
LIVE_PIPELINE_MODE=true mix zer0_media.dev
```

When the control plane uses a non-default local port, pass it explicitly:

```sh
LIVE_PIPELINE_MODE=true mix zer0_media.dev --control-plane-url http://localhost:4001
```

This starts the HTTP server on port `8080` and the RTMP listener on port `1935`.
It uses the `dev` Mix environment by default. With LivePipeline enabled, the
legacy Boombox runtime is not prepared; no production compilation is required.
It also uses the local control-plane secret already configured by
`zer0_stream/config/dev.exs`; production still requires
`CONTROL_PLANE_AUTH_SECRET`.

Publish to:

```text
rtmp://localhost:1935/live/<stream-key>
```

The worker validates the stream key through the control plane, creates a live
session, demuxes H.264 and AAC through Membrane, and writes a sliding HLS
playlist and CMAF segments (audio + video) to
`priv/hls/stream-session-<id>/master.m3u8`.

WebRTC viewers connect to `/webrtc/<session_id>` on the shared HTTP origin.
Each socket gets its own signaling relay, peer connection and temporary crash
group. HLS drives the shared source; a slow or disconnected viewer cannot
backpressure HLS or another viewer. Audio is currently transcoded to Opus per
viewer, so CPU and outgoing bandwidth grow with the viewer count.

Video timestamps now default to a scale of `1.0`, preserving the publisher's
frame rate and bitrate. The previous `0.5` default compressed the timeline and
could double both. For existing deployments, remove `VIDEO_TIMESTAMP_SCALE=0.5`
or set it to `1.0`, then restart the stream. Use another scale only for a
publisher with a verified timestamp error. `AAC_TIMESTAMP_RATE` also defaults
to `1.0`; clock corrections remain opt-in.

AAC timestamps are passed through `Zer0Media.AudioTimestampNormalizer` before
reaching the HLS muxer. It rebases PTS/DTS to start at zero and applies a
linear clock-rate correction (`rate`, default `1.0`, i.e. no correction) so
the audio timeline can be tuned to match the video timeline when a publisher's
encoder drifts. Override the default with:

```sh
AAC_TIMESTAMP_RATE=1.008 \
mix run -e '{:ok, _pid} = Zer0Media.RTMPServer.start_link(port: 1935); Process.sleep(:infinity)'
```

`1.008` is the measured steady-state correction for the current OBS/publisher
setup. A single early data point (from a `:track_timing_mismatch_at_sync`
error at ~76s) initially suggested `1.002665`, but that underestimated the
drift — comparing multiple sync points across a run shows the video/audio gap
growing by a constant 64ms every 8s (a steady 0.8% clock-rate difference, not
random jitter), which solves to a steady-state rate of `1/(1 - 0.008) ≈
1.008065`. When re-deriving this from a packager error, prefer at least two
data points spread apart and fit the linear trend
(`gap = a + b * video_elapsed_seconds`, `rate = 1 / (1 - b)`) rather than a
single-point ratio, since single points taken early in a run underestimate
the asymptotic rate.

Tune this by comparing the accumulated audio duration reported in the HLS
muxer's sync warnings/errors against the elapsed video duration over a long
test run, then set `rate` to the ratio needed to bring them back in line.
If audio/video segment groups fail to sync (`:vod` mode is strict and fails
fast on packager errors), that is a sign the rate still needs adjustment for
that publisher.

LivePipeline uses `Membrane.HTTPAdaptiveStream.SinkBin` in live mode, with
separate audio/video CMAF playlists and a 20-second target window. Its segment
target defaults to one second. Configure it with `HLS_SEGMENT_DURATION_MS`
(e.g. `2000` for two seconds); use a fixed OBS keyframe interval compatible with
the target. Actual video cuts still depend on publisher keyframes.

Timing is validated at application startup. `LLHLS_PART_DURATION_MS` defaults to
`200` and must not exceed the segment target, and only enables partial output when `LLHLS_ENABLED=true`. The deprecated `HLS_SEGMENT_DURATION` variable still means
nanoseconds (`4000000000` = four seconds); migrate it to
`HLS_SEGMENT_DURATION_MS=4000`. Do not set both. Values must be positive whole
milliseconds, at most 60 seconds.

Completed HLS artifacts are retained for 60 seconds by default
(`HLS_CLEANUP_GRACE_MS`). Startup removes stale session directories, so this
storage is not an archive. RTMP idle cleanup defaults to 15 seconds
(`RTMP_IDLE_TIMEOUT_MS`) and handles publishers that omit `deleteStream`.

The experimental LL-HLS path now persists real CMAF parts and serves authenticated
blocking playlists/preload objects. Enable it with `LIVE_PIPELINE_MODE=true` and
`LLHLS_ENABLED=true`; the existing frontend is not switched automatically.
See [LL-HLS setup and HTTP contract](../docs/llhls-origin.md) and
[media architecture](../docs/media-architecture.md). Standard HLS remains available.
Browser/CDN acceptance and end-to-end latency measurements are still pending.

While the publisher is live, inspect the manifest and segments in that
directory. A non-empty manifest with advancing segments is the first playback
path proof.

## Serving HLS over HTTP

The worker starts an HTTP server (`Zer0Media.HLSRouter`, via Bandit) on
startup that serves the directory tree written by `Zer0Media.LivePipeline`. It listens on port `8080` by default; override with `HLS_HTTP_PORT`.

Playback URLs are rooted at `/hls/`, mirroring the on-disk layout:

```text
http://localhost:8080/hls/stream-session-<id>/master.m3u8
```

Requests outside of the configured `hls_dir` are rejected (403), and missing
files return 404. Browser CORS is restricted to the comma-separated origins in
`HLS_ALLOWED_ORIGINS`; production must set this value to the zer0.tv player
origins, such as `https://zer0.tv,https://www.zer0.tv`.

Test playback by pointing Safari (native HLS support) or an HLS-capable
player (e.g. `hls.js`, VLC, `ffplay`) at the `master.m3u8` URL for an active
or completed stream session.

Set `CONTROL_PLANE_URL` through application configuration when the control
plane is not running at `http://localhost:4000`.

## WebRTC / LivePipeline mode

Set `LIVE_PIPELINE_MODE=true` to run the Membrane `LivePipeline`, which ingests
RTMP and tees the stream to **both** HLS and WebRTC from a single source. This is
the production path (the Boombox path below is legacy).

```sh
LIVE_PIPELINE_MODE=true \
WEBRTC_PUBLIC_URL_TEMPLATE=wss://stream.dev.zer0.tv/webrtc/:session_id \
TURN_URL=turn:192.168.1.1:3478?transport=udp \
TURN_PUBLIC_URL=turn:199.193.114.34:3478?transport=udp \
TURN_SECRET=<coturn-auth-secret> \
mix zer0_media.dev --control-plane-url http://localhost:4001
```

- **Signaling** is served on the shared HTTP origin (port 8080) at
  `/webrtc/<session_id>`, so it flows through the existing `stream.dev.zer0.tv`
  reverse proxy with no extra Caddy route.
- **TURN** is used for NAT traversal. `TURN_URL` is the server-side TURN server
  (use the LAN address when on the same network as coturn); `TURN_PUBLIC_URL` is
  the public TURN server handed to the browser. `TURN_SECRET` must match coturn's
  `static-auth-secret`.
- The WebRTC legs are linked on demand (only when a viewer connects) and live in
  a temporary crash group so a WebRTC failure doesn't take HLS down.

See [`../webrtc.md`](../webrtc.md) and [`../ENV_VARS.md`](../ENV_VARS.md).

## Concurrent Viewer Counts

The worker reports **concurrent HLS playback clients**, not unique users. A
valid playlist, init-segment, or media-segment request for
`stream-session-<id>` renews that client's heartbeat. The default heartbeat TTL
is 30 seconds (`VIEWER_TTL_SECONDS`); a client disappears from the count after
it stops requesting HLS media for that interval. The live count is in-memory,
approximate, and can lag a disconnect by up to the TTL.

The worker identifies a playback client by deriving a stable `viewer_id` from
the **verified v2 playback token** (legacy tokens use SHA-256 of the token), which is present on every request
in a playback session. This avoids generating a new viewer per request when the
`SameSite=Lax` `zer0_viewer_id` cookie isn't sent back on cross-origin
subresource requests (which previously inflated the count). Custom clients can
also send a stable, opaque `viewer_id` query parameter (1-128 bytes) on every
playlist and segment request.

`GET /api/sessions/:id/viewers` is an internal control-plane route. It returns
the current snapshot for the session ID encoded in the HLS path:

```json
{
	"session_id": 42,
	"viewer_count": 3,
	"updated_at": "2026-08-16T12:00:00Z"
}
```

It requires the existing `CONTROL_PLANE_AUTH_SECRET`, shared only by the worker
and control plane. The control plane signs
`GET\n/api/sessions/:id/viewers\n<unix timestamp>\n{}` using the same 60-second
HMAC-SHA256 scheme as its worker ingest requests. The endpoint returns `401` for
missing, expired, or invalid signatures. It never returns stream keys, playback
tokens, or viewer IDs.

zer0.tv must call `GET /api/streams/:id/viewers` on the control plane instead.
That main-app-authenticated endpoint resolves the live session and reads the
worker internally, so no extra viewer-count secret is required.

Every `VIEWER_SNAPSHOT_INTERVAL_MS` (30 seconds by default), the worker sends
the raw concurrent count for each recently active stream session to the control
plane. The control plane stores append-only samples in PostgreSQL with its own
timestamp; no viewer IDs, stream keys, or playback tokens are persisted. This
makes the historical series survive worker restarts. The main app can retrieve
up to 1,000 durable samples and their arithmetic mean through its normal
service authentication at `GET /api/streams/:id/viewer-metrics?limit=100`.

## Legacy Boombox path (not WebRTC)

The **LivePipeline path above is the production path**. The Boombox path is
legacy: it uses a supervised Boombox process per session and only produces HLS
(no WebRTC). It is still the default when `LIVE_PIPELINE_MODE` is unset, and
writes `priv/hls-boombox/stream-session-<session-id>.m3u8` served at
`/hls-boombox/...`. For Boombox, use `LIVE_PIPELINE_MODE=false` and leave `LEGACY_HLS_MODE` unset.
Despite its name, `LEGACY_HLS_MODE=true` currently bypasses Boombox and uses
`BOOMBOX_RELAY_URL` if configured; it does not override LivePipeline. These
legacy semantics are preserved pending an explicit mode migration.

Boombox lives in the sibling `boombox_runtime/` Mix app because its dependency
graph is incompatible with the media worker's control-plane dependencies. The
worker prepares it automatically in the active Mix environment before listening
for RTMP, then starts it for each live session. No standalone probe process or
manual local compilation is required.

Start the worker in Boombox mode:

```sh
mix zer0_media.dev
```

OBS still publishes to `rtmp://localhost:1935/live/<stream-key>`. The worker
starts the Boombox process automatically and writes
`priv/hls-boombox/stream-session-<session-id>.m3u8`, served at
`http://localhost:8080/hls-boombox/stream-session-<session-id>.m3u8`. The
standalone probe remains available for isolated experiments, but is no longer
needed for the supervised worker path.
```



### TURN dependency patch

The worker uses tracked `vendor/ex_ice` (0.16.1 plus the patch documented in
`vendor/ex_ice/ZER0_PATCHES.md`). It preserves the relay transport when a
successful ICE check returns a mapped address different from the TURN
allocation, avoiding a public-address priority lookup crash. The Dockerfile
copies this dependency before fetching dependencies. Rebuild and redeploy the
media worker image to apply it; restarting an existing image is insufficient.

### Viewer TURN quotas and mobile fallback

With `TURN_SECRET`, credentials now use a separate stable identity for each
viewer and for the worker/browser sides, rather than sharing the `zer0` user.
Each signaling connection sends fresh browser credentials in an `ice_servers`
message before SDP. This avoids sharing the per-user allocation quota across
an entire stream and avoids reusing credentials generated at stream start.
Static `TURN_USERNAME`/`TURN_PASSWORD` credentials remain shared by design.

Deploy both the worker and frontend for this change. The frontend retains HLS
while probing WebRTC, bounds retries, and closes connections on navigation.
Coturn's total quota still counts allocations across all users; it is not a
viewer limit. `stale-nonce` governs authentication nonce expiry, not allocation
capacity. Keep quota settings while retesting; size the total quota according
to measured concurrent allocation use as the audience grows.
