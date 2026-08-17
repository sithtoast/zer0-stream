# zer0-stream

The streaming backend control plane for zer0.tv. It owns creators, streams, and
ingest credentials independently from the discovery application.

## Local development

Run the development application directly with Mix. PostgreSQL is a separate
local service, matching the zer0.tv development workflow:

```sh
cd /Users/wmh/Dev/zer0-stream/zer0_stream
createdb zer0_stream_dev
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

The API is available at `http://localhost:4000`.

## Control-plane endpoints

- `POST /api/control/creators` creates a streaming creator.
- `POST /api/control/streams` creates a stream for a creator.
- `POST /api/control/creators/:id/keys` rotates a creator's ingest key. The raw
  key is returned only in this response and only its SHA-256 hash is stored.
- `POST /api/ingest/rtmp/authorize` validates an RTMP stream key and opens a
  live stream session.
- `POST /api/ingest/rtmp/:connection_id/stop` closes an RTMP stream session.
- `GET /api/streams/:id/viewers` returns the current concurrent viewer count.
- `GET /api/streams/:id/viewer-metrics?limit=100` returns durable viewer
  samples and their arithmetic mean. `limit` defaults to 100 and is capped at
  1,000.
- `GET /api/health` checks service health.

The two viewer endpoints use the same main-app authentication as playback. An
unknown stream returns `404`. An offline stream returns `200` with
`{"stream_id": id, "viewer_count": 0, "live": false}` from the live endpoint,
and an empty sample list with an average of `0.0` from the historical endpoint.
Timestamps are UTC ISO-8601 values.

Each creator has one channel record. Its ingest key belongs to the creator, so
the RTMP publish URL stays stable when channel metadata changes.

The RTMP adapter in `Zer0Stream.Ingest.RTMPAdapter` is the boundary for the
future network listener and Membrane pipeline. It owns authorization and
session lifecycle; it does not yet parse RTMP bytes or transcode media.

## Media dependency boundary

The maintained `membrane_rtmp_plugin` package is available, but its current
dependency graph requires Decimal 2 through Ratio. This control plane uses
Ecto 3.14 and patched Decimal 3 because older Decimal releases have a known
security advisory. Do not force both graphs into this application. The RTMP
listener and Membrane pipeline should be introduced as a separate media worker
or service with its own dependency lockfile, connected to this control plane
through the adapter contract above.

## Container deployment

Docker is for CI and production deployment. PostgreSQL stays outside the app
container and is supplied through `DATABASE_URL`:

```sh
DATABASE_URL=ecto://user:password@db-host:5432/zer0_stream_prod \
SECRET_KEY_BASE=replace_me \
PHX_HOST=stream.example.com \
docker compose up --build
```

The production compose file does not define a database service. Run migrations
against the external database as part of deployment before starting the new
application image.

