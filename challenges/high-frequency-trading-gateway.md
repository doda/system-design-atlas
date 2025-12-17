## Elegance Check

### The Core Insight
A single-writer event loop + explicit `gw_seq` is the right “elegant core” for microsecond determinism: it turns correctness (ordering, idempotency, risk state) into a local property instead of a distributed one.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| `Gateway Core` (single writer) | Deterministic ordering, bounded work, no locks/queues on the hot path |
| `NIC (polling)` | Removes scheduler/interrupt jitter that dominates µs tail latency |
| `Exchange Sessions` (non-blocking) | Venue protocol correctness (seq/resend/heartbeats) without stalling the core |
| `Event Log` (append-only decisions) | Audit + crash reconstruction without putting “storage correctness” in the hot path |
| `Reconciler` (off-path) | Makes “eventual correctness” real by comparing to authoritative sources |
| `Telemetry` focused on drops/tails | Operators need leading indicators for loss/jitter/backpressure |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “Event Log” description is vague | Make it explicit: single local append-only segment log (preallocated, checksummed) with an async flush policy; optionally memory-mapped | Less flexibility than “pluggable sinks,” but much clearer operationally; avoids accidental “Kafka on the hot path” |
| Ad-hoc idempotency tables keyed by `(client_order_id, session)` + `(exchange_order_id)` | Use one canonical internal `order_key` assigned at accept; keep only a fixed-size hash table keyed by `(session, clOrdId)` to map to `order_key` | Slightly more plumbing, but simplifies every later lookup/state transition |
| “Throttle resend processing off-path” is underspecified | Treat resends as a separate input class with a hard budget per tick (N messages) and explicit priority rules | You may delay full catch-up, but you preserve bounded latency (the stated goal) |
| Risk arrays “indexed by preassigned IDs” | Centralize ID registry + snapshot (account/symbol → compact ID) loaded at start; reject unknown IDs fast | Less dynamic onboarding, but removes tail-risk from runtime resizing/mapping |
| Exchange session “never block the core” | Use a single-producer ring per session (core → session TX) + a bounded RX ring (session → core) | More rings, but much simpler than trying to make protocol handling “sort of inline” without blocking |

## Stress Test

### Failure Scenarios
1. **Event log sink slows down (disk hiccup, fsync stalls, log writer CPU starved)**
   - Design’s answer: “reject at ingress if risk log buffer full”
   - Recommendation: Strengthen — define durability semantics explicitly (what’s acceptable to lose on crash?) and make backpressure thresholds/runbooks concrete (segment rollover, disk-full behavior, max tolerated lag).

2. **Exchange one-way trouble: outbound packets drop but inbound still arrives (or vice versa)**
   - Design’s answer: “seq-gap alarms, heartbeat misses, resync session”
   - Recommendation: Strengthen — specify how you detect “write-only failure” vs “read-only failure” and when you force `PendingNew` orders to fail closed to avoid phantom live orders.

3. **Gateway restart during heavy retry storm (clients time out and resend while you’re rebuilding state)**
   - Design’s answer: replay log reproduces decisions; idempotency makes retries safe
   - Recommendation: Strengthen — define the “no-trade window” and the exact acceptance rule while warming (e.g., reject all until `gw_seq`/order table restored, or accept only cancels); otherwise you’ll accept orders you can’t yet dedupe.

4. **Bad config push (risk limits wrong, symbol band mis-set for market orders, kill switch inverted)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — add config versioning + atomic activation + “dry-run validation” (parse + invariants + canary shard) and a one-command rollback; in HFT, bad config is the common failure, not exotic faults.

5. **Traffic 10x burst with partial component degradation (NIC ok, but exchange session becomes intermittently unwritable)**
   - Design’s answer: reject under backpressure; scale by sharding
   - Recommendation: Acceptable if you add per-venue fairness rules (prevent one clogged venue from consuming the entire core budget) and a clear client-facing reject taxonomy that trading systems can act on.

## Recommendations

### Must Fix
- Define event-log durability: what is guaranteed (decision persisted before send? best-effort audit only?) and what happens on crash between accept/send/log.
- Specify restart/warmup behavior: when you reject/accept, how dedupe tables are rebuilt, and how you avoid “accepting before you can be idempotent.”
- Make resend/late-fill handling algorithmic (budgets, priority, invariants), not just narrative; otherwise tail latency will be “policy-dependent” in production.

### Should Consider
- Add explicit fairness/budgeting in the event loop (per input class: new orders, cancels, fills, resends) so “bounded work” is mechanically enforced.
- Formalize invariants + fail-closed triggers (e.g., reservation can’t go negative; per-account exposure monotonic rules per event type; if violated → kill-switch + reject).
- Clarify sharding + client routing ownership (consistent hashing, sticky routing, failover story); the design is elegant per-shard, but the system becomes complex at the edges.

### Nice to Have
- A minimal, auditable “decision record” schema (binary, fixed-size) so replay is fast and deterministic across versions.
- A safe deployment story: canary shard, config gates, and a latency regression tripwire (auto-disable new build if p99 exceeds threshold).

## What’s Working Well
- The design is honest about what matters: determinism and bounded latency over maximal uptime.
- Reservations vs realized position is the correct mental model for constant-time risk under fills/cancels.
- Backpressure-as-reject (not hidden queues) is the right move for µs systems and makes failure behavior legible.
- Keeping reconciliation off-path is pragmatic: it lets the hot path stay simple while still achieving correctness over time.