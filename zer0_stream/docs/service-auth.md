# Service Authentication

Privileged API requests use HMAC-SHA256 signatures with a 60-second timestamp
window. Each service has the least-privileged secret required for its routes.

| Caller | Secret | Allowed routes |
| --- | --- | --- |
| zer0.tv main app | `MAIN_APP_AUTH_SECRET` | `/api/control/*`, `/api/streams/:id/playback` |
| media worker | `CONTROL_PLANE_AUTH_SECRET` | `/api/ingest/*` |

Send these headers on every privileged request:

- `x-zer0-timestamp`: current Unix time in seconds
- `x-zer0-signature`: unpadded base64url HMAC-SHA256 signature

The signature input is the UTF-8 string below:

```text
<UPPERCASE HTTP method>\n<request path>\n<timestamp>\n<canonical JSON body>
```

Canonical JSON sorts object keys lexicographically at every nesting level, uses
compact JSON, and preserves array order. For the playback `GET`, sign an empty
JSON object: `{}`. The receiver returns `401` for expired, malformed, or
wrong-scope signatures.

## Idempotent Writes

`POST /api/control/streams` requires a caller-generated `request_id` in its JSON
body. Retrying with the same `request_id` returns the original stream with `200`;
the first successful request returns `201`. Use a fresh, opaque request ID for
each intended stream creation.