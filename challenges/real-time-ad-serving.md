## Elegance Check

### The Core Insight
Make the bidder’s request path constant-time by (1) compiling targeting into shard-level candidate pools and (2) turning “global budget correctness” into “local, fast, bounded spend” via short-lived, region-scoped token balances.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| RTB Gateway | Enforces strict deadlines early; normalizes OpenRTB quirks so bidders stay simple and predictable. |
| Bidder Fleet | Horizontally scalable hot path; where latency budgets must be enforced stage-by-stage. |
| Campaign Control Plane | Only place that should do expensive compilation/pacing logic; enables safe rollout/rollback of config. |
| Redis (Features) | Low-latency feature access with explicit fallbacks; avoids DB fanout and tail spikes. |
| Redis (Tokens) | Single-digit ms atomic decrements for budget gating; isolates coordination from per-request logic. |
| Kafka Event Log | Immutable audit trail for billing + training; decouples hot path from reconciliation. |
| Stream Reconciler | Establishes “truth” from events; corrects drift and closes the loop for pacing. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “publish snapshots/deltas to bidders” | Use a Kafka compacted topic for campaign state (keyed by campaign/shard), bidders consume + keep in-memory view | Adds Kafka dependency to bidder startup/recovery path; but removes bespoke distribution/rollback machinery. |
| Redis tokens with multi-step idempotency (`SETNX` then `DECRBY`) | Single Redis Lua script that atomically: check idempotency key → decrement by price → set idempotency key with TTL | Slightly more Redis scripting/ops; materially reduces double-spend on crash/retry edge cases. |
| Separate “win-handler” path implied but not fully specified | Make win handling a dedicated stateless service (HTTP ingest) that only does idempotent token spend + event emit | Extra service, but keeps bidder hot path lean and isolates exchange callback variability. |
| Candidate pools “in bidder memory” only | Store versioned snapshots in S3/object storage + distribute via CDN; bidders fetch on rollout | Adds snapshot management, but simplifies large fanout, avoids GC spikes, and improves rollback to a known artifact. |
| “Spend on win” with potential missed auctions | Consider optional “soft reservation” on bid (small, short TTL) + reconcile on win | More complexity; improves budget utilization and reduces lost bids when win notices are delayed. |
| Region allocation for overspend bounding | Start with region-only, but add “campaign group cap” as a second limiter using the same token primitive | More token keys/logic; prevents portfolio-level overspend when many campaigns share a parent cap. |

## Stress Test

### Failure Scenarios
1. **Redis (tokens) is up but slow (p99 jumps to 20–50ms)**
   - Design's answer: fail closed / no-bid for budgeted campaigns; strict step budgets
   - Recommendation: Strengthen — add a “budget-check fast timeout” (e.g., 2–3ms) plus a clearly defined premium-mode fallback (e.g., limited in-memory micro-credits per bidder with hard upper bound) so latency SLOs don’t imply total revenue collapse during partial degradation.

2. **Network partition: bidders can’t reach Redis, but can reach Kafka**
   - Design's answer: no-bid (tokens unavailable), deterministic degradation rules
   - Recommendation: Acceptable — but explicitly quantify the business impact: “partition ⇒ revenue to ~0 for budgeted campaigns in affected region” and ensure on-call has a single lever (feature K downshift + circuit breaker) rather than ad-hoc tuning.

3. **Bad config / compiler bug publishes a broken candidate pool version**
   - Design's answer: staged rollout + instant rollback; control plane owns safety
   - Recommendation: Strengthen — require “bidder-side validity gates” (schema/version checks + min-size sanity checks + canary shard metrics) so rollback can trigger automatically when `no_bid_reason=filtered` spikes or candidate pool becomes empty.

4. **Kafka unavailable for 5 minutes**
   - Design's answer: not explicitly addressed (events are “immutable facts” but hot path coupling isn’t defined)
   - Recommendation: Must strengthen — define whether bidders buffer locally (bounded) vs drop vs sync-write; for billing/audit you generally want: hot path never blocks on Kafka, but events are durably buffered (local disk queue) with backpressure + a clear “degraded but serving” mode.

5. **Duplicate / out-of-order win notifications and price mismatches**
   - Design's answer: idempotent keys (`bid_id`), reconcile drift
   - Recommendation: Strengthen — specify the exact idempotency key (exchange + auction_id + imp_id), the atomic spend primitive (Lua), and the source of truth for spend amount (clearing price from win notice). This is where 3am bugs tend to hide.

## Recommendations

### Must Fix
- Specify an atomic token-spend operation (idempotency + decrement + TTL) to eliminate crash/retry double-spend edge cases.
- Define Kafka-down behavior (buffering/backpressure/drop policy) so billing/training correctness isn’t accidental.
- Make config rollout safety measurable: canary + automatic rollback triggers tied to `no_bid_reason`, candidate pool health, and spend-vs-plan anomalies.

### Should Consider
- Consider a compacted Kafka topic as the primary distribution channel for compiled state (removes bespoke snapshot/delta plumbing, improves replay).
- Clarify “truth” boundaries: what must be consistent in Redis vs what is eventually corrected by the reconciler; document the allowed overspend bound mathematically (per region + lease slack + failure window).
- Decide if “spend on win” is sufficient for your exchanges; if win notices are delayed/spotty, add an optional soft reservation to reduce missed revenue without reverting to global counters.

### Nice to Have
- Explicit multi-region story for Postgres/control plane (active-active vs active-passive) and what happens to pacing when control plane is impaired.
- A single operational “kill switch” per tier (premium/standard) for feature fallback, K reduction, and token strictness.
- Document key sizing/hotspot strategy (Redis Cluster key tags, shard cardinality, and worst-case key contention).

## What's Working Well
- The design is honest about the real problem: bounded latency under massive concurrency with mutable constraints, not just “ranking ads.”
- Control-plane/data-plane separation is the right elegance move: it keeps the bidder operationally simple and makes correctness mostly a reconciliation/policy problem.
- Deterministic degradation rules + `no_bid_reason` as a first-class metric is exactly how you keep incidents from becoming debates.
- Region-scoped budgets are a clean, understandable way to bound overspend under partitions without pretending you can have global strong consistency in <100ms.