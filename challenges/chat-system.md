## Elegance Check

### The Core Insight
Separating **durable truth** (append-only message log + monotonic watermarks) from **best-effort real-time UX** (WebSockets/typing/presence) is the right abstraction: it makes missed events a performance issue, not a correctness bug.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Postgres (messages + membership + receipts) | Single transactional truth for sync correctness, authorization, and monotonic receipt updates |
| WebSocket Gateway | Keeps connection state out of the API tier; isolates backpressure and slow-client handling |
| Redis (ephemeral real-time) | Low-latency broadcast channel where loss is acceptable by design |
| Push Worker | Separates latency-sensitive send path from policy-heavy push delivery |
| Edge (L7) | Connection upgrade, limits, and shielding gateways from abuse |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| `receipts.last_delivered_id` stored server-side per *user* | Make “delivered” purely device-local, store only `last_read_id` server-side (or store delivered per-device) | Less server state, avoids multi-device correctness traps; weaker “delivered to user” semantics unless you model devices |
| ULID as the sole ordering key (`WHERE message_id > cursor`) | Use DB time ordering: `(created_at, message_id)` cursor with `created_at = now()` on insert | Slightly larger cursor; clearer ordering definition and less risk from clock skew/non-monotonic ULID generation |
| Publish to Redis in the request path | Transactional outbox table in Postgres + async publisher for Redis/push | Adds a worker/table, but prevents “committed message, no event” gaps and simplifies retries/observability |
| “Every gateway gets every message_created, then filters locally” | Shard real-time channels by `hash(conversation_id)` so gateways subscribe only to shards they need | More routing complexity; big win when gateway count and QPS are high |
| Redis Pub/Sub for all real-time | Redis Streams (at-least-once) *only* for message_created, keep typing/presence on Pub/Sub | Slightly more ops, but protects the one event you most want to deliver quickly without making correctness depend on it |

## Stress Test

### Failure Scenarios
1. **Postgres down for 5 minutes**
   - Design’s answer: partially addressed (sync is correctness path, but everything depends on Postgres)
   - Recommendation: Strengthen — define explicit degraded mode (reject sends fast, queue nothing in-memory), and ensure clients backoff with jitter; document RPO/RTO expectations and how you fail over (replica promotion, connection pool behavior).

2. **“Committed but not broadcast” (API commits message, Redis publish fails/timeouts)**
   - Design’s answer: implied acceptable (clients reconcile via sync)
   - Recommendation: Strengthen — acceptable for “real-time UX”, but not for push reliability; add outbox for push and (optionally) for message_created to keep the system observable and reduce support tickets (“I sent it but they didn’t get notified”).

3. **Multi-device user (phone + laptop) advances `last_delivered_id`**
   - Design’s answer: not addressed
   - Recommendation: Must fix — storing delivered watermark per user can cause one device to “skip” messages another device never downloaded. Either (a) make delivered cursor device-local only, or (b) store it per `(conversation_id, user_id, device_id)`.

4. **Large group hot-spot (100k members, many active, 10x traffic spike)**
   - Design’s answer: addressed at a high level (rate limits, partitioning, degrade typing/push)
   - Recommendation: Strengthen — call out the real-time broadcast amplification risk (gateways receiving all events); add sharded pub/sub (or routing) and per-conversation protection (token bucket + enforced slow-mode).

5. **Bad deploy / schema/index regression**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — include “safe deploy” primitives: feature flags for new event types, backward-compatible cursor formats, and a rollback story for partitions/index migrations (especially with 2B msgs/day).

## Recommendations

### Must Fix
- Clarify cursor ownership: `last_delivered_id` should be **device-scoped** or **client-only**; keep `last_read_id` user-scoped.
- Define ordering precisely: either guarantee monotonic ULIDs (and document generator requirements) or switch to `(created_at, message_id)` cursors to avoid ambiguous timelines.
- Make push delivery durable: add an outbox (or unread-scanner) so push doesn’t silently drop during Redis/API hiccups.

### Should Consider
- Add membership timeline fields (`joined_at/joined_msg_id`, `left_at/left_msg_id`) so sync can enforce “what you were allowed to see” under joins/leaves/bans.
- Shard the real-time channel fanout so gateways don’t all process every conversation’s traffic at peak.
- Add retention/archival (e.g., older partitions → S3) so Postgres stays operable at multi-year scale.

### Nice to Have
- Formalize event priority: message_created > receipt_update > typing/presence, with explicit shedding rules and metrics.
- Document idempotency table TTL/cleanup and unique constraints (`(sender_id, client_msg_id)`), plus retry-safe insert patterns.
- Provide a “supportability” section: how to answer “where is my message?” with trace IDs across API → DB → event → gateway → client.

## What’s Working Well
- The “durable log + monotonic watermarks” model is clean, teachable, and resilient to flaky networks.
- The design explicitly treats real-time as **optimization**, which avoids the classic correctness trap.
- The large-group approach (“fanout to active sessions, not all members”) is the right lever against write amplification.
- Backpressure-first gateway guidance (disconnect slow clients, recover via sync) is pragmatic and operationally sound.