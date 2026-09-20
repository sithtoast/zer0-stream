# LL-HLS coordinator baseline

Local synthetic measurement, 2026-09-19. Elixir 1.20.3, OTP 29, 18 online
schedulers. One run on the developer Mac, not a throughput/latency SLO.
Run `MIX_ENV=test mix run --no-start bench/llhls_waiters.exs` from `media_worker`.
No HTTP listener, media encoder, network or CDN is involved.

| Concurrent callers | One event through all replies | Process bytes / blocked caller | Incremental bytes / caller over idle | Timeout wave (1s timers) |
|---:|---:|---:|---:|---:|
| 100 | 0.777 ms | 4,199 | 1,451 | 1,001.072 ms |
| 1,000 | 3.207 ms | 3,665 | 974 | 1,009.948 ms |
| 5,000 | 16.881 ms | 3,485 | 796 | 1,047.081 ms |

All three runs had one distinct waiting target. Server mailbox length was zero
at the fully registered and drained snapshots. Every timeout wave returned zero
retained waiters/targets; server process memory after cleanup/GC was 2,848–2,960
bytes. These snapshots do not measure peak mailbox size during the burst.

A six-segment, sixty-part playlist occupied 3,684 bytes and took 30.216 microseconds
per render averaged over 1,000 renders. One publication renders once regardless
of waiting viewer count. Figures include application-level scheduling and replies;
process memory sums caller/server process heaps and excludes TLS/socket memory,
allocator overhead and some off-heap structures. Incremental figures depend on
heap allocation/GC and should not be treated as total per-HTTP-viewer cost.

Use this baseline to test changes, not to justify a language rewrite or claim
production capacity. Repeat through Bandit and a reverse proxy after the origin
is integrated, including request cancellation, distinct wait targets, sustained
part publication and client churn.
