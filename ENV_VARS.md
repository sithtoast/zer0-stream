# Environment Variables by Component

Reference for the environment variables each service in the zer0-stream stack reads.
Use this when deploying, debugging cross-service connections, or onboarding a new
environment.

## Components

| Component | Directory | Role | Default port |
|---|---|---|---|
| **media_worker** | `media_worker/` | RTMP ingest + Membrane pipeline (HLS + WebRTC) | 1935 (RTMP), 8080 (HTTP) |
| **control plane** | `zer0_stream/` | Streaming API, sessions, playback tokens, lifecycle webhooks | 4000 |
| **chat** | `chat/` | Chat WebSocket service | 4100 |
| **frontend** | `twitch-elixir/` | The zer0.tv web app / channel pages | 4000 |

## Shared secrets (must match across services)

These are the cross-component values that cause "it connects but auth fails" bugs
when they drift. **Keep each one identical on every service that shares it.**

| Secret | Services that must agree | Used for |
|---|---|---|
| `CHAT_TOKEN_SECRET` | frontend + chat | Signing/verifying chat WebSocket tokens |
| `MAIN_APP_AUTH_SECRET` | frontend + control plane | Authorizing frontend → control-plane API calls |
| `CONTROL_PLANE_AUTH_SECRET` | control plane + media_worker | Authorizing media_worker → control-plane ingest calls |
| `LIFECYCLE_WEBHOOK_SECRET` | control plane + frontend | Verifying control-plane → frontend lifecycle webhooks |
| `PLAYBACK_TOKEN_SECRET` | control plane (+ media_worker) | Signed HLS playback URLs |

---

## media_worker (`media_worker/`)

### Mode

| Var | Default | Notes |
|---|---|---|
| `LIVE_PIPELINE_MODE` | `false` | `true`/`1` = use the Membrane `LivePipeline` (HLS **and** WebRTC tee). **Required for WebRTC.** Otherwise Boombox mode is used. |
| `LEGACY_HLS_MODE` | `false` | `true`/`1` = force Boombox mode. |

### WebRTC / TURN

| Var | Default | Notes |
|---|---|---|
| `WEBRTC_PUBLIC_URL_TEMPLATE` | `ws://localhost:8080/webrtc/:session_id` | Public signaling URL; `:session_id` is replaced per session. e.g. `wss://stream.dev.zer0.tv/webrtc/:session_id` |
| `TURN_URL` | — | TURN server for the WebRTC **sink** (server side). Use the LAN address when on the same network as coturn: `turn:192.168.1.1:3478?transport=udp` |
| `TURN_PUBLIC_URL` | `TURN_URL` | TURN server handed to the **browser** (must be public): `turn:199.193.114.34:3478?transport=udp` |
| `TURN_SECRET` | — | coturn `static-auth-secret`. Must match the Auth Secret in the OPNsense coturn config. |
| `TURN_USERNAME` / `TURN_PASSWORD` | — | Static TURN credentials (alternative to `TURN_SECRET`). |
| `STUN_URL` | `stun:stun.l.google.com:19302` | STUN server override. |

### HTTP / HLS / ingest

| Var | Default | Notes |
|---|---|---|
| `HLS_HTTP_PORT` | `8080` | HTTP port for the HLSRouter (also serves `/webrtc/<session>` signaling). |
| `RTMP_PORT` | `1935` | RTMP ingest port. |
| `HLS_DIR` | `priv/hls` | HLS output directory. |
| `HLS_SEGMENT_DURATION` | `1` | HLS segment duration. |
| `HLS_ALLOWED_ORIGINS` | `http://localhost:3000,http://localhost:4000` | CORS allowed origins for HLS. |
| `RTMP_IDLE_TIMEOUT_MS` | `15000` | Idle RTMP timeout. |
| `LOG_LEVEL` | `info` | Log level. |
| `VIEWER_TTL_SECONDS`, `VIEWER_SNAPSHOT_INTERVAL_MS` | — | Viewer tracking tuning. |

### Control-plane connection

| Var | Default | Notes |
|---|---|---|
| `CONTROL_PLANE_AUTH_SECRET` | — | Must match the control plane's value. |
| `--control-plane-url` (CLI) / `:control_plane_url` | — | Control plane base URL, e.g. `http://localhost:4001`. |

### Boombox mode only

`BOOMBOX_RELAY_URL`, `BOOMBOX_RUNTIME_DIR`, `BOOMBOX_INPUT_URL`, `BOOMBOX_OUTPUT`,
`BOOMBOX_WEBRTC_PORT`, `BOOMBOX_SESSION_ID`, `BOOMBOX_MIX_ENV`.

---

## control plane (`zer0_stream/`)

| Var | Default | Notes |
|---|---|---|
| `PORT` | `4000` | HTTP port. |
| `PHX_HOST` | `localhost` | Public host. |
| `PHX_SERVER` | — | Set `true` to start the HTTP server. |
| `SECRET_KEY_BASE` | — | Phoenix secret (required in prod). |
| `DATABASE_URL` | — | Postgres URL (required in prod). |
| `POOL_SIZE` | `10` | DB pool size. |
| `DNS_CLUSTER_QUERY` | — | Optional DNS cluster. |
| `PLAYBACK_BASE_URL` | `http://localhost:8080` | Base URL used to build HLS playback URLs. |
| `PLAYBACK_TOKEN_SECRET` | `dev-playback-secret` | Secret for signed playback URLs. |
| `MAIN_APP_AUTH_SECRET` | — | Shared with the frontend. |
| `CONTROL_PLANE_AUTH_SECRET` | — | Shared with the media_worker. |
| `MEDIA_WORKER_URL` | `http://media_worker:8080` | Where the control plane reaches the media worker. |
| `LIFECYCLE_WEBHOOK_URL` | — | Frontend webhook URL for lifecycle events. |
| `LIFECYCLE_WEBHOOK_SECRET` | — | Shared with the frontend. |

---

## chat (`chat/`)

| Var | Default | Notes |
|---|---|---|
| `PORT` | `4100` | HTTP/WebSocket port. |
| `CHAT_TOKEN_SECRET` | `dev-chat-token-secret` | **Must match the frontend's `CHAT_TOKEN_SECRET`.** Chat won't connect if these differ. |
| `DATABASE_URL` | — | Postgres URL (required in prod). |
| `SECRET_KEY_BASE` | — | Phoenix secret (required in prod). |
| `PHX_HOST` | `example.com` | Public host. |
| `PHX_SERVER` | — | Set `true` to start the server. |
| `CHAT_ALLOWED_ORIGINS` | `http://localhost:4000` | Comma-separated origins allowed to open WebSocket connections (`check_origin`). **Must include the frontend's origin.** |
| `DNS_CLUSTER_QUERY` | — | Optional DNS cluster. |
| `POOL_SIZE` | `10` | DB pool size. |

---

## frontend (`twitch-elixir/`)

| Var | Default | Notes |
|---|---|---|
| `PORT` | `4000` | HTTP port. |
| `PHX_HOST` / `PHX_SERVER` | — | Phoenix host / server flag. |
| `SECRET_KEY_BASE` | — | Phoenix secret. |
| `DATABASE_URL` | — | Postgres URL. |
| `TWITCH_CLIENT_ID` / `TWITCH_CLIENT_SECRET` | — | Twitch OAuth. |
| `TWITCH_REDIRECT_URI` | — | Twitch OAuth callback. |
| `ZER0_STREAM_API_URL` | — | Control-plane API base URL, e.g. `https://api.dev.zer0.tv`. |
| `MAIN_APP_AUTH_SECRET` | — | Shared with the control plane. |
| `LIFECYCLE_WEBHOOK_SECRET` | — | Shared with the control plane. |
| `CHAT_SOCKET_URL` | `ws://localhost:4100/socket` | Chat WebSocket URL. **In internet-facing env use the public one, e.g. `wss://chat.dev.zer0.tv/socket`.** |
| `CHAT_TOKEN_SECRET` | `""` | **Must match the chat service's `CHAT_TOKEN_SECRET`.** |
| `PUBLIC_URL` | — | Public base URL for generated links. |

---

## Troubleshooting: chat not connecting

The chat connection needs **four things** to line up. Check them in order:

1. **`CHAT_SOCKET_URL` is reachable from the viewer's browser.**
   The default is `ws://localhost:4100/socket`, which only works when the browser
   is on the same machine as the chat service. From the internet it must be the
   public URL, e.g. `wss://chat.dev.zer0.tv/socket` (proxied by Caddy to the chat
   service). If it's still `localhost`, the browser tries its own machine and fails.

2. **`CHAT_TOKEN_SECRET` matches on the frontend and the chat service.**
   The frontend signs a chat token with `CHAT_TOKEN_SECRET`; the chat service
   verifies it with its own `CHAT_TOKEN_SECRET` (same salt `"chat-user"`, max age
   1h). If they differ, `Phoenix.Token.verify` fails and the socket refuses the
   connection (`:error`). This is the most common silent cause.

3. **`CHAT_ALLOWED_ORIGINS` (chat service) includes the frontend's origin.**
   In prod the chat service rejects WebSocket handshakes from origins not in this
   list (`check_origin`). If the frontend is at `https://www.zer0.tv`, that origin
   must be present.

4. **The viewer actually has a chat token.**
   The channel page only renders the chat panel when `chat_token` is non-nil. That
   requires a logged-in viewer **and** chat access (channel `chat_access_mode ==
   "open"` or the viewer has a chat grant). Anonymous viewers or viewers without
   access get no token and no chat panel.

### Quick checks

- From the viewer's machine, confirm `wss://chat.dev.zer0.tv/socket` resolves and
  the chat service is up (Caddy → chat service).
- Compare `CHAT_TOKEN_SECRET` between the frontend and chat service — they must be
  byte-identical.
- Confirm `CHAT_ALLOWED_ORIGINS` on the chat service lists the frontend origin.
- Check the chat service logs for `:error` on socket connect (token verify failure)
  vs. a network/`check_origin` rejection — they look different and point to
  different fixes.
