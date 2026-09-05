# Viewer identity and rollout

The navbar counts unique global presence keys: a logged-in user ID, otherwise
an anonymous browser session ID. The frontend derives an opaque HMAC identity
from that key using its endpoint secret. All frontend instances must share that
secret; rotating it changes viewer identities.

The frontend sends that identity in the authenticated JSON body of POST
`/api/streams/:id/playback`. The control plane signs it into a v2 playback token.
The media worker verifies the signature, stream and expiration before using the
identity for both HLS requests and WebRTC pipeline heartbeats. Token renewal and
multiple tabs no longer create extra viewers. Different viewers receiving tokens
in the same second remain distinct.

Legacy GET playback requests and legacy tokens remain supported. Legacy tokens
retain token-hash counting until they expire, so old and new playback may briefly
count separately during rollout.

Deploy in this order:

1. Media worker (accepts legacy and v2 tokens).
2. Control plane (supports authenticated POST playback).
3. twitch-elixir frontend (requests identity-bearing tokens).

No new database migration or environment variable is needed for this change.
To roll back, revert the frontend first and allow v2 tokens to expire (one hour)
before reverting the worker's token support.

The figures still differ in scope and timing: navbar presence covers the site;
playback covers media activity for one stream with a default 30-second inactivity
expiry and a 20-second frontend refresh. External media playback need not have a
LiveView connection. Paused players may keep fetching media and remain counted.
Channel presence marks watching on playback and clears it on pause/offline; its
watching breakdown deduplicates identities per source and channel.
