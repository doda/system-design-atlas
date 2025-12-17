## Elegance Check

### The Core Insight
Per-event single-writer (“seat ledger”) + sharding by `event_id` is the right abstraction: it turns a messy distributed-lock problem into a bounded serialization problem with a clean UX contract (fast yes/no) and a clear scaling axis (more events → more shards).

### Components That Earn Their Place
| Component | Why It’s Necessary |
|-----------|---------------------|
| Waiting Room | Converts bursty, adversarial traffic into stable allocator load; fairness lever against bots. |
| Seat Allocator (per-event leader) | Explicit serialization point that prevents DB lock herds/deadlocks and makes outcomes predictable. |
| Postgres (holds/orders + constraints) | Durable truth + last-line-of-defense invariants (“no double-sell” even under bugs/failover). |
| CDN + WAF | Keeps origin focused on the hard part (writes); reduces bot/noise and static asset load. |
| Payment integration with idempotency | Externalizes long latency while keeping a single authoritative order outcome. |
| Redis (limits/tokens) | Useful accelerator for abuse controls and cheap rejection paths (but should remain optional). |
| Coordination store (etcd/consul) | Leader election for “exactly one active writer” semantics per shard. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| etcd/consul leases for shard leadership | Postgres advisory locks keyed by `event_id`/shard | Fewer moving parts, but PG becomes part of coordination path; need careful timeout/lock-leak handling. |
| Background “reaper” as key seat-freeing mechanism | Lazy expiration on write path (reclaim expired holds inline) + periodic cleanup | Slightly more write-path logic, but avoids “stuck seats until reaper runs” during incidents. |
| Redis hold-token registry for fast invalid-token reject | Pure signed capability tokens + DB check on “interesting” paths only | More DB lookups under attack; mitigated by waiting room + WAF + per-identity limits. |
| In-memory availability view per leader with periodic reconcile | Store precomputed section bitsets in PG/Redis and serve via dedicated read service | More infra/data pipeline work, but clearer read/write separation and faster warmup/recovery. |
| Custom waiting room | Managed/edge waiting room (Cloudflare/Akamai/Fastly) | Less control over fairness semantics; faster time-to-operate and fewer on-call pages. |

## Stress Test

### Failure Scenarios
1. **Postgres down for 5 minutes**
   - Design’s answer: partially addressed (“PG is truth”, “prefer correctness over availability”), but admission/UX behavior isn’t fully specified.
   - Recommendation: Strengthen — explicitly stop/slow admissions per event, return a deterministic “sales paused” response, and define what happens to existing holds (they will expire by time, but purchases should fail fast with clear messaging).

2. **Network partition / split-brain leaders for the same event**
   - Design’s answer: relies on uniqueness constraints to prevent corruption; doesn’t fully address “two leaders both think they’re active.”
   - Recommendation: Must fix — add fencing: include a monotonic “leader epoch” (lease revision) on every write and persist it in PG, rejecting writes from stale epochs. This reduces conflict storms and makes failover behavior crisp.

3. **One component is slow (PG lock waits, storage hiccup) but not down**
   - Design’s answer: not addressed in detail; risk is allocator queue buildup → timeouts → retries → amplified contention.
   - Recommendation: Strengthen — bound per-event in-flight/queue length, shed load with explicit backoff headers, and prefer “best available”/reduced features automatically when latency crosses thresholds.

4. **Bad config / deploy (wrong shard mapping, TTLs, or token validation bug)**
   - Design’s answer: operational notes mention visibility, but not safe rollout/guardrails.
   - Recommendation: Strengthen — canary per event cohort, config validation with invariants (TTL bounds, key rotation windows), and a “kill switch” to force read-only / pause admissions per event.

5. **Traffic 10x unexpectedly (retry storm + bots adapt)**
   - Design’s answer: waiting room + rate limits acknowledged; good foundation.
   - Recommendation: Acceptable if tightened — ensure client retries are capped server-side (idempotency + explicit `Retry-After`), and make the waiting room the *only* path to allocator for hot events (no bypass endpoints).

## Recommendations

### Must Fix
- Add split-brain fencing (epoch/lease token persisted and checked in Postgres writes).
- Ensure expired-hold reclamation works even if the reaper is delayed (avoid “stuck seats” under incident conditions).
- Define hold vs `PENDING_PAYMENT` semantics (what reserves seats once payment starts, for how long, and what expires first).
- Handle clock skew explicitly (token TTL and `expires_at` comparisons need leeway and server-time authority).
- Specify admission behavior when PG is unavailable (pause/slow + clear UX, not vague 5xx).

### Should Consider
- Replace etcd/consul with Postgres advisory locks if your team wants fewer primitives (and you can tolerate PG being in the control plane).
- Make Redis strictly best-effort (design so correctness and basic UX survive Redis loss without opening a bot floodgate).
- Formalize per-event fairness inside the leader (FIFO/priority rules, starvation prevention, and deterministic tie-breaking).
- Clarify read consistency for availability deltas (staleness bounds, and what users see during failover/warmup).

### Nice to Have
- Managed waiting room at the edge to reduce operational load.
- Partitioning/retention strategy for `holds/held_seats/orders` to prevent bloat-driven latency incidents.
- One-command runbooks: “who owns event X?”, “why is event X rejecting holds?”, “drain shard safely.”

## What’s Working Well
- The design is honest about the real problem (contention + fairness) and chooses an elegant serialization point instead of accidental distributed locking.
- Defense-in-depth is strong: single-writer for performance, Postgres constraints for correctness, idempotency for retries.
- Degradation paths (“best available”) and per-event observability focus are exactly what makes this operable under peak load.