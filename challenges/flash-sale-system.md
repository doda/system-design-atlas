## Elegance Check

### The Core Insight
Treat the flash sale as **admission control + scarce reservations**, not “scale the checkout path”: a stable, server-issued queue position prevents retry-gaming, and a bounded reservation rate prevents hot-spot collapse.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| CDN/Edge | Converts 500k RPS into cached/static + cheap hits; protects origin. |
| Waiting Room | Single public surface during spike; enforces backpressure and “one story” for users. |
| Ticket Issuer | Creates a **stable ordering** once; eliminates retry advantage. |
| Redis (atomic + TTL) | Correct under extreme contention for counters/holds; TTL makes expiry cheap. |
| Postgres Orders | Durable audit + correctness backstop (uniqueness, reconciliation, reporting). |
| Order Queue | Decouples admission from slow payment/order writes; keeps front door stable. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate Waiting Room + Ticket Issuer | Merge into one “Queue Service” (join/poll/admit in one place) | Fewer hops/services; slightly larger blast radius if it fails. |
| Custom monotonic ticket via Redis `INCR` + per-user ticket key | Use Redis `SETNX ticket:{...}` with “allocate range” blocks (e.g., `INCRBY` per worker) | More throughput and less hot counter contention; slightly more complex issuer logic. |
| Redis holds + “recycle via reconciler increment on expiry” | Recompute `remaining` periodically from source of truth (`starting - sold - active_holds`) and **treat Redis remaining as a cache** | Fewer edge-case bugs from increment-on-expiry; more read/compute cost and needs careful performance. |
| Order Queue unspecified | Use a managed queue (SQS/Kafka) or Postgres outbox + workers | Less custom ops; may add cost/latency, and Kafka adds ops if self-managed. |
| Admission rate as manual knob | Closed-loop controller (rate = f(redis remaining, payment p95, queue depth)) | Better automatic stability; requires careful tuning to avoid oscillation. |
| “One ticket per account” plus device signals | Put bot gating *before join* using a managed anti-bot/attestation product | Stronger fairness protection; risk of false positives and UX friction. |

## Stress Test

### Failure Scenarios
1. **Redis down for 5 minutes**
   - Design’s answer: stop admissions; waiting room stays up; fail closed.
   - Recommendation: Strengthen — add an explicit “sale paused, keep your place” state and ensure *poll* endpoints stay cacheable even when origin is degraded.

2. **Network partition: Admission API can reach Waiting Room but not Redis**
   - Design’s answer: implied “reserve fails closed”.
   - Recommendation: Strengthen — require a short-lived “admission token” (signed) and only mint it when Redis is reachable; otherwise you’ll churn user turns and destroy perceived fairness.

3. **Ticket Issuer overload / hot counter contention**
   - Design’s answer: autoscale; prioritize idempotent reads.
   - Recommendation: Strengthen — define a hard cap on new joins per second + use counter range allocation to avoid a single hot `INCR` becoming the bottleneck.

4. **Bad config deploy (e.g., admission rate too high, TTL too long, wrong SKU inventory)**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen — add guardrails: max admit/sec, max holds <= starting inventory, feature-flagged sale open/close, and “two-person” change for inventory/TTL during event.

5. **One component slow-but-not-failing (payments p95 spikes)**
   - Design’s answer: admission tied to downstream health (conceptually).
   - Recommendation: Strengthen — specify the control signal (queue depth + payment latency) and the fail-safe behavior (rapid ramp-down, slow ramp-up) to avoid feedback oscillations.

## Recommendations

### Must Fix
- Define a **single source of truth** for inventory math and make reconciliation deterministic (avoid “increment on expiry” edge cases; prefer recompute-from-facts or a clearly correct event model).
- Prevent “burning turns”: ensure users only get admitted when the system can actually create holds (admission token tied to Redis health).
- Clarify idempotency scope: keys for `join`, `reserve`, and `place order`, and what happens on client logout/login/device switch.

### Should Consider
- Collapse Waiting Room + Ticket Issuer into one service to reduce ops surface area (unless you have a clear org/team boundary).
- Make the queue “honest”: expose explicit states (queued, admitted, paused, sold out) so UX remains stable during incidents.
- Replace bespoke order queue with a managed option or Postgres outbox if the team is small and on-call load matters.

### Nice to Have
- Multi-SKU behavior: confirm whether tickets are per SKU or per sale (users will perceive unfairness if they can “queue-hop” SKUs).
- Formalize fairness threat model (retry scripts, multi-account, device farms) and what you will/won’t stop.
- Add chaos drills/runbooks: “Redis degraded”, “pause sale”, “recompute remaining”, “rollback config”.

## What’s Working Well
- Clear separation between **fair ordering**, **reservation correctness**, and **async finalization**.
- Correct instinct to keep most of the system boring and concentrate complexity in two places that matter.
- Idempotency and uniqueness constraints are treated as first-class, which is usually what saves these systems in real incidents.
- Honest trade-off: single-region ordering authority avoids “global fairness theater” and keeps operations tractable.