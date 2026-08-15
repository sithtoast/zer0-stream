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
mix run -e '{:ok, _pid} = Zer0Media.RTMPServer.start_link(port: 1935); Process.sleep(:infinity)'
```

Publish to:

```text
rtmp://localhost:1935/live/<stream-key>
```

The worker validates the stream key through the control plane, creates a live
session, demuxes H.264 and AAC through Membrane, and writes a sliding HLS
playlist and CMAF segments (audio + video) to
`priv/hls/stream-session-<id>/master.m3u8`.

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

The local smoke-test default uses thirty-second segments so it works with the
current publisher's variable keyframe interval. The publisher's GOP length is
not fixed and has been observed anywhere from roughly 4 to 9 seconds, so
raising `HLS_SEGMENT_DURATION` above the last observed max is only a stopgap:
a longer run can still produce a GOP that exceeds it and crash the strict
`:vod` packager (`Segment duration ... exceeds target ... (RFC 8216
violation)`).

The durable fix is to give OBS a fixed keyframe interval instead of variable:
Settings → Output → Advanced mode → Streaming tab → Keyframe Interval `2`
(seconds). With a fixed interval, run the worker with a matching segment
duration, e.g. `HLS_SEGMENT_DURATION=4000000000`, and GOPs can no longer drift
past the target. This also moves the pipeline toward the low-latency target
segment size instead of the 8-30s workaround durations.

The local pipeline uses `{:event, safety_delay}` synchronization rather than
strict `:vod`. Measured audio drift is not a fixed clock-rate ratio: it comes
from OBS's separate, unsynchronized audio/video capture threads, so it varies
session to session and can't be fully cancelled by a single static
`AAC_TIMESTAMP_RATE`. In strict `:vod` mode, any `track_timing_mismatch_at_sync`
is fatal; in `:event`/`:sliding` mode the packager skips the offending sync
point instead of crashing the pipeline (see `Membrane.HLS.SinkBin`'s
timing-contract docs). `AAC_TIMESTAMP_RATE` is still worth tuning to reduce
how often that happens, but it's no longer a hard requirement for the stream
to stay up. `safety_delay` defaults to the configured `HLS_SEGMENT_DURATION`
and can be overridden separately with `HLS_SAFETY_DELAY` (nanoseconds).
Sliding LL-HLS (`{:sliding, max_segments, safety_delay}`) is the next tuning
step once event-mode playback is verified stable.

While the publisher is live, inspect the manifest and segments in that
directory. A non-empty manifest with advancing segments is the first playback
path proof.

## Serving HLS over HTTP

The worker starts an HTTP server (`Zer0Media.HLSRouter`, via Bandit) on
startup that serves the same directory tree `Zer0Media.HLSPipeline` writes
to. It listens on port `8080` by default; override with `HLS_HTTP_PORT`.

Playback URLs are rooted at `/hls/`, mirroring the on-disk layout:

```text
http://localhost:8080/hls/stream-session-<id>/master.m3u8
```

Requests outside of the configured `hls_dir` are rejected (403), and missing
files return 404. Responses include a permissive CORS header so a browser
player on a different origin/port can fetch the manifest and segments; this
should be tightened once signed playback tokens are added.

Test playback by pointing Safari (native HLS support) or an HLS-capable
player (e.g. `hls.js`, VLC, `ffplay`) at the `master.m3u8` URL for an active
or completed stream session.

Set `CONTROL_PLANE_URL` through application configuration when the control
plane is not running at `http://localhost:4000`.

## Temporary Boombox packaging probe

The worker uses the supervised Boombox path by default. Each authorized session
gets its own local RTMP listener and Boombox process. To temporarily roll back
to the legacy direct HLS path, set `LEGACY_HLS_MODE=true`.

Boombox lives in the sibling `boombox_runtime/` Mix app because its dependency
graph is incompatible with the media worker's control-plane dependencies. Build
it once before starting the worker (and during deployment):

```sh
cd ../boombox_runtime
MIX_HOME=../.mix-boombox HEX_HOME=../.hex-boombox mix deps.get
MIX_HOME=../.mix-boombox HEX_HOME=../.hex-boombox mix compile
```

The worker starts `boombox_runtime` automatically for each live session; no
standalone probe process or Docker RTMP relay is required.

Start the worker in Boombox mode:

```sh
mix run -e '{:ok, _pid} = Zer0Media.RTMPServer.start_link(port: 1935); Process.sleep(:infinity)'
```

OBS still publishes to `rtmp://localhost:1935/live/<stream-key>`. The worker
starts the Boombox process automatically and writes
`priv/hls-boombox/stream-session-<session-id>.m3u8`, served at
`http://localhost:8080/hls-boombox/stream-session-<session-id>.m3u8`. The
standalone probe remains available for isolated experiments, but is no longer
needed for the supervised worker path.
```


