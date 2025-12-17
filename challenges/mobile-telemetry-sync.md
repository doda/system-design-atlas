## Elegance Check

### The Core Insight
Treat telemetry as a **device-local append-only log** and make the network protocol optimize for **rare, deliberate flushes**; then recover “effectively-once” semantics via **batch-level idempotent commit** instead of per-event coordination.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Mobile SDK local log | Enables batching, survivability across app kills/reboots, and decouples collection from upload windows. |
| Batch-level commit record | The one correctness primitive that makes retries cheap and downstream clean. |
| Durable Queue | Absorbs burstiness (updates/outages) so the edge API can stay fast and stable. |
| Object Storage (immutable blobs) | Cheap, replayable source of truth for raw telemetry with decoupled retention/backfill. |
| Ingest Worker | Moves heavy decompress/validate/write off the latency-sensitive upload path. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| **Dedup Cache** as primary duplicate defense | Make the **commit table** authoritative with a **unique constraint** on `(device_id, batch_seq)`; keep cache as an optimization only | Slightly higher write contention on the DB during retry storms, but far simpler correctness story. |
| Custom chunk protocol (`missing_ranges` / offsets) | Use a standard resumable protocol (e.g., **tus**) or **S3/GCS multipart upload** + `ListParts` | Less bespoke logic, but you accept object-store semantics and integrate their auth/expiry patterns. |
| Upload API handles bytes + resumability + enqueue | Split into **control plane** (auth, policy, commit) and **data plane** (direct-to-object-store via presigned URLs) | More moving pieces, but removes large payload handling from your fleet of APIs and makes scaling easier. |
| “Events Index DB” as a separate concept | Use **Postgres** for commit + index metadata initially (partitioned tables), then graduate to stream/lakehouse later | Might need careful partitioning/vacuuming at scale, but it’s operationally simpler for a medium system. |
| Server-driven policy hints as bespoke response schema | Use standard headers (`Retry-After`, `ETag`, cacheable policy docs) + a versioned “policy manifest” endpoint | Slightly less expressive per-response, but clearer caching/versioning and fewer ad-hoc fields. |

## Stress Test

### Failure Scenarios

1. **Commit DB is down for 5 minutes**
   - Design’s answer: not addressed (queue + cache are mentioned, but the “unique and immutable commit record” needs a durable home)
   - Recommendation: **Strengthen** — define the commit store explicitly and behavior when unavailable: return `503` + `Retry-After`, and ensure no “success” is returned unless the commit is durably recorded.

2. **Dedup cache is cold/evicted during a retry storm**
   - Design’s answer: dedup cache TTL makes duplicates cheap, but doesn’t say what prevents double-commit if cache misses
   - Recommendation: **Must fix** — treat cache as best-effort; enforce idempotency with a DB uniqueness constraint (or conditional write in DynamoDB/etcd). Cache should only reduce read/load, not guarantee correctness.

3. **Worker crashes after writing blob but before updating index/commit**
   - Design’s answer: implies a single commit point, but doesn’t specify atomicity across blob + commit
   - Recommendation: **Strengthen** — make worker idempotent with a write ordering: (a) ensure blob exists, (b) insert commit with CAS/unique key, (c) update index/status. On replay, detect existing commit and no-op.

4. **Network partition / region failover causes the same device to hit two Upload APIs**
   - Design’s answer: not addressed
   - Recommendation: **Strengthen** — ensure idempotency scope is global (commit store reachable/replicated) or enforce consistent routing by `device_id` (sticky region) with a clear failover story (and what happens to in-flight multipart uploads).

5. **Device reinstall / clock skew / counter reset produces `batch_seq` reuse**
   - Design’s answer: hash mismatch becomes hard error + “log repair”
   - Recommendation: **Acceptable, but clarify** — define the repair path: new `device_instance_id` (or epoch) that’s part of the idempotency key, and how the server signals “you’ve reset; start a new epoch” without bricking uploads.

## Recommendations

### Must Fix
- Make the **commit record store** explicit and authoritative; enforce idempotency with **unique constraints / conditional writes**, not cache TTLs.
- Define atomicity/idempotency across **partial upload storage + commit** (especially if the Upload API is “stateless” but resumability implies server-side state).
- Specify how the server derives/trusts `device_id` (ideally from auth token, not request body) to prevent cross-tenant collisions and replay abuse.

### Should Consider
- Adopt **tus** or **object-store multipart** to delete a large chunk of custom resumability logic (and lean on proven edge cases).
- Split control-plane vs data-plane (presigned uploads) if payload volume starts stressing the Upload API; it also makes “minimal wakeups” easier (fewer retries through a busy API tier).
- Clarify ordering semantics: what happens with **out-of-order batches**, **gaps in event_seq**, and how much the server cares (tracking “expected next” can be optional but very useful for debugging).

### Nice to Have
- Add explicit backpressure contracts: when to return `429` vs `503`, and how policy hints are cached/versioned.
- Add a “fleet safety” kill-switch policy (sampling to 0%, smaller max batch bytes) with strict rollout/rollback semantics.
- Document operational SLOs: acceptable commit lag, max queue depth, and what dashboards/on-call runbooks look like.

## What’s Working Well
- The design optimizes the *right* primitive for mobile: **radio wakeups and retries**, not HTTP elegance.
- Batch-level commit is a clean correctness boundary: it keeps server-side dedupe/state **O(batches)** and makes downstream analytics sane.
- Server-driven policy hints are a strong operability lever (incident response without app releases), and the trade-offs are stated honestly.
- The “fast accept vs heavy validate” evolution path is pragmatic and keeps today’s design from overreaching.