## Elegance Check

### The Core Insight
Two-stage dispatch (cheap candidate narrowing + fast, sticky local assignment) reframes “dispatch” as a streaming optimization loop that stays stable under churn and imperfect signals, instead of chasing global optimality.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Order Service + Postgres | Clear lifecycle invariants, auditability, reconciliation, and hard uniqueness constraints for “no double-assign.” |
| Dispatch Engine (stateless) | Keeps the only “smart” logic restartable; algorithm iteration without state-loss fear. |
| Redis | Hot loop state (courier presence, locks, dedupe) at 15k updates/s without hammering Postgres. |
| Durable Event Log | Replay/shadow runs and decoupling; absorbs bursts; enables deterministic postmortems. |
| Routing/ETA | Centralizes “truth” for travel-time primitives so dispatch/user surfaces don’t diverge. |
| API Gateway | Rate limiting and request shaping so client chaos can’t destabilize dispatch. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Redis used for “locks + dedupe + geo/time indexes” | Use Postgres for correctness boundaries only (unique constraints + `SELECT … FOR UPDATE SKIP LOCKED`), keep Redis strictly for location/geo | Higher DB load; but makes correctness story simpler and reduces “split brain” surfaces. |
| Crypto idempotency key for offers | Plain idempotency keys with scoped uniqueness in Postgres (`offers(idempotency_key)` unique) | Less “fancy,” same property; cryptography rarely buys you much unless you’re preventing forgery across trust boundaries. |
| Per-event recompute | Fixed per-zone tick (even at moderate scale), with event coalescing as input | Adds latency ceiling (~tick interval), but reduces thrash and makes capacity planning easier earlier. |
| Custom fairness term in scoring | Start with simple constraints + quotas (min offers per zone/courier cohort) enforced outside scoring | Less optimal smoothing, but much more debuggable and safer to tune. |
| Redis geo buckets | Consider a dedicated geo index only if needed; otherwise H3 buckets stored in Postgres for static-ish data (restaurants/zones) | Postgres won’t handle courier updates at 15k/s well; but for restaurant/zones it may delete a subsystem. |

## Stress Test

### Failure Scenarios

1. **Kafka/event log is down for 5 minutes**
   - Design’s answer: not addressed (assumes event backbone)
   - Recommendation: Strengthen  
   Add an explicit degraded mode: Order Service continues to accept orders and write Postgres; Dispatch switches to polling “ready/unassigned” via Postgres (or an outbox table) per zone until the log recovers; ensure idempotent re-emission when Kafka returns.

2. **Redis is down or partially partitioned**
   - Design’s answer: implicitly critical (hot state + locks live there)
   - Recommendation: Strengthen  
   Define what correctness relies on in Postgres (assignments) vs what is “best effort” (candidate sets). If Redis is down: disable batching, reduce to conservative assignment using last-known courier positions from a slower store (or “only couriers currently active in last N seconds” from a fallback presence stream). Also define Redis cluster mode, persistence expectations (AOF?) and what data loss means operationally.

3. **Network partition between Dispatch and Postgres**
   - Design’s answer: partial (Postgres uniqueness prevents double-assign, but dispatch may continue emitting offers)
   - Recommendation: Strengthen  
   Make “offer emission” conditional on the ability to write/confirm offer state durably (at least for accepted offers). Otherwise you’ll spam couriers with offers you can’t finalize. Consider: dispatch emits “proposed offers” to courier only after Postgres insert succeeds, or uses a local outbox that is reconciled.

4. **Slow routing/ETA provider (not failing, just p95 spikes)**
   - Design’s answer: mentions caching/precompute later, but not immediate behavior
   - Recommendation: Strengthen  
   Add strict budget: dispatch scoring must not block on live routing calls. Use a tiered approach: cheap heuristic ETA (grid speed + historical) in the hot path; async refine ETA and only re-offer if improvement crosses a threshold (stickiness). Also set circuit breakers and fallback profiles.

5. **Bad config/algorithm rollout causes offer storm**
   - Design’s answer: kill switch + debounce/rate-limit described
   - Recommendation: Acceptable, but tighten  
   Make the kill switch granular (per zone, per restaurant cohort, per batch size) and ensure it’s “fast + safe”: config served from a highly available source, audited, with a default-safe fallback on config fetch failure. Require canary + shadow evaluation gates before enabling batching changes broadly.

## Recommendations

### Must Fix
- Define explicit degraded modes for loss of: event log, Redis, routing/ETA, and Postgres connectivity (what continues, what stops, and how you recover without compounding inconsistency).
- Clarify the single source of truth for each state: offer existence, offer acceptance, assignment, courier capacity/slots, and “current route commitments” (and what happens on worker restart).
- Make routing calls non-blocking in the dispatch critical path with a clear fallback ETA model and circuit breakers.

### Should Consider
- Consider moving from per-event recompute to bounded per-zone ticks earlier; it’s often simpler to reason about and easier to protect with budgets.
- Simplify fairness: start with explicit quotas/guards and metrics, then evolve to a scoring term once you have stable observability.
- Tighten operational control plane: zone drains, freeze reassignments, disable batching, disable reoffers, and “only assign ready orders” as separate toggles.

### Nice to Have
- More explicit “explainability contract”: store top-N features/constraints that caused the choice (and which guardrail eliminated other candidates).
- Formal SLOs per dependency (Redis, Kafka, routing), and automated “mode switch” policies tied to those SLOs.

## What’s Working Well
- Clear prioritization: stable, explainable near-optimal decisions beats fragile “optimal” solvers.
- Correctness boundary is mostly in the right place (Postgres constraints + idempotency) with Redis accelerating the hot loop.
- Guardrails for batching and explicit “kill switch” thinking show good operational maturity.
- Replay/shadow runs via event log is the right lever for safer iteration on heuristics and incident debugging.