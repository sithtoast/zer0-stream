# Lifecycle Webhooks

Set `LIFECYCLE_WEBHOOK_URL` to enable outbound lifecycle events. The control
plane sends `stream.started` after a new RTMP session commits and
`stream.stopped` after the final live session for a stream ends.

Each request is a JSON `POST` with this envelope:

```json
{
  "id": "event-id",
  "type": "stream.started",
  "occurred_at": "2026-08-15T12:00:00Z",
  "data": {
    "stream": {"id": 42, "creator_id": 7, "title": "Live", "status": "live"},
    "session": {"id": 99, "connection_id": "...", "protocol": "rtmp", "status": "live"}
  }
}
```

The receiver verifies the following headers:

- `x-zer0-timestamp`: Unix seconds. Reject stale requests; the sender emits it
  immediately before delivery.
- `x-zer0-signature`: unpadded base64url HMAC-SHA256 using
  `LIFECYCLE_WEBHOOK_SECRET` over the exact UTF-8 payload
  `"<timestamp>\n<raw request body>"`.

Events are persisted transactionally with the associated stream transition.
Delivery is asynchronous and does not block ingest authorization or disconnect
handling. Failed deliveries retry with exponential backoff up to 10 attempts;
the receiver must deduplicate with the envelope `id` because a sender crash
between sending and recording success can cause a repeat delivery.