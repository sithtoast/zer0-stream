# zer0-stream planning document

## Recommendation

A separate repository is the correct boundary for the streaming backend. The current zer0.tv app is a discovery application with PostgreSQL-backed web access patterns and a different scaling profile from a live ingest and transcoding service. Keeping the streaming backend separate avoids deploy coupling, runtime coupling, and media dependency bloat.

## Product goals

- Accept live ingest from creator tools
- Publish stream state and metadata to the zer0.tv app
- Deliver low-latency HLS playback
- Support authenticated creator access and signed playback URLs
- Keep the streaming service independently scalable and independently deployable

## Core architecture decisions

### 1. Separate service boundary

- `zer0.tv` remains the discovery, browsing, and account surface
- `zer0-stream` owns streaming identities, ingest keys, session state, and media processing
- The two services communicate through a thin API contract and signed callbacks
- A shared database is avoided in the initial version

### 2. Use Membrane for the media pipeline

Membrane is the correct Elixir-native tool for media ingest, processing, and packaging. It provides a strong foundation for:

- RTMP input handling
- WHIP ingest support
- Transcoding and normalization
- HLS / LL-HLS packaging
- Stream monitoring and pipeline health

### 3. Prefer low-latency HLS over WebRTC first

- RTMP first for broad creator compatibility
- WHIP as a follow-on integration
- Low-latency HLS as the initial public playback format
- WebRTC playback remains optional and can be considered after the core pipeline is stable

### 4. Keep auth and identity decoupled

- The streaming service should own its own stream/account records
- It should validate a signed token or service-issued credential from zer0.tv rather than directly reusing the existing database schema
- Use short-lived ingest credentials and signed playback tokens
- Rotation and revocation should be enforced at the streaming-auth layer

## Service responsibilities

### zer0.tv app responsibilities

- Discover streams and creators
- Display stream metadata and browse pages
- Manage user-facing auth sessions and profile pages
- Call the streaming service for stream state and auth metadata
- Consume stream online/offline events from the backend

### zer0-stream responsibilities

- Manage creator streaming accounts and stream keys
- Accept live ingest and enforce access controls
- Build and monitor media pipelines
- Package streams into HLS manifests and segments
- Deliver playback URLs with time-limited auth
- Emit stream status and lifecycle events back to zer0.tv

## Initial milestone

### Public beta foundation

This milestone should deliver the smallest useful system:

- One streaming service per deployment
- RTMP ingest support
- Creator-specific ingest credentials
- Low-latency HLS origin output
- CDN-backed playback
- Signed playback URLs
- Broadcast start/stop lifecycle events
- Separate config, Dockerfile, and deployment pipeline from zer0.tv

## API contract

The contract between zer0.tv and zer0-stream should be narrow and explicit.

### Stream metadata contract

- creator id
- stream id
- title
- category or tags
- status
- started_at
- thumbnail_url
- viewer_count
- health status

### Authorization contract

- issue scoped ingest credentials for a creator
- validate stream key or signed session token at ingest time
- issue playback tokens for a stream session
- enforce expiration and revocation

### Event contract

- stream.started
- stream.stopped
- stream.updated
- stream.health_changed
- stream.error

These events should be server-to-server calls or signed webhook-style callbacks, not database cross-coupling.

## Data model

The streaming service should own its own tables, including:

- users / creators
- streams
- stream_keys
- stream_sessions
- media_pipelines
- manifests
- playback_tokens
- metrics and health events

The zer0.tv app should not directly read streaming service tables. It should consume a clean API response or event stream instead.

## Deployment model

### Initial deployment

- independent Docker service
- independent PostgreSQL instance or isolated schema
- object storage and CDN for playback origin/content
- independent health checks and deployment pipeline

### Later evolution

- optional multi-node deployment
- regional origin/edge split
- autoscaling on pipeline load
- additional recording and moderation features

## Operational requirements

- limit ingest bitrate and resolution per creator
- track stream health and restart gracefully
- isolate failures per stream
- log pipeline crash reasons
- enforce signed request validation on all callbacks
- keep session IDs idempotent for reconnect scenarios

## Recommended rollout order

1. Create the separate zer0-stream repository and Docker stack
2. Add creator account + stream key model
3. Add RTMP ingest endpoint and validation
4. Add Membrane pipeline for normalization and packaging
5. Add low-latency HLS output to object storage or origin
6. Add signed playback token generation
7. Add stream lifecycle events to zer0.tv
8. Add creator dashboard and status UIs
9. Add WHIP support as a later phase

## Risks to avoid

- sharing the zer0.tv database with the media backend
- monolithic deployment of ingest/transcoding into the discovery app
- direct user-auth reuse without a signed service trust boundary
- using WebRTC or full low-latency delivery before RTMP + HLS is proven
- overbuilding to a multi-region, auto-scaling platform before the single-host path is stable

## Media dependency boundary

The maintained `membrane_rtmp_plugin` package was checked during the RTMP
spike. It compiles on the current Elixir/OTP toolchain, but its current Ratio
dependency requires Decimal 2. The control plane uses Ecto 3.14 with patched
Decimal 3 because Decimal versions below 3.0 have a security advisory.

Do not force an override or downgrade the control plane to make those graphs
coexist. Keep RTMP/Membrane processing in a separately pinned media worker or
service and connect it to the control plane through `Zer0Stream.Ingest.RTMPAdapter`.

## Conclusion

The correct design is a separate Elixir service using Membrane and Docker, with a narrow API contract to zer0.tv. The first milestone should aim for a production-like RTMP + low-latency HLS public beta, not an all-in-one live platform. This keeps the streaming backend capable of growing without dragging the existing zer0.tv product into a different operational model.
