## Elegance Check

### The Core Insight
Use Postgres as the durable truth, but make the *scheduler’s hot path* operate on **tenants-first** (a small, bounded set) so fairness and isolation are enforceable without a global “ready jobs” hotspot.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Postgres | Atomic state transitions + `SKIP LOCKED` claiming + durable auditability (the correctness backbone). |
| Scheduler (stateless) | The only place where fairness/quotas/backoff policy lives; keeps workers simple and disposable. |
| Worker fleet | Provides elastic execution capacity; failures are contained via leases + retries. |
| Observability | Tenant isolation only “exists” if you can see per-tenant lag/saturation and act quickly. |
| Payload blob store (implied) | Keeps the DB hot set small and avoids oversized rows dominating IO/vacuum. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| `tenant_state` + advisory lock per tenant | Lock the `tenant_state` row with `SELECT ... FOR UPDATE` and drop advisory locks | Easier correctness model; row becomes a contention point if you also update it from many codepaths. |
| Persistent “deficit round robin” | Start with deterministic ordering `(next_ready_at, tenant_id)` + per-tenant caps; add DRR only if needed | Less “perfect” fairness under saturation; dramatically simpler to implement/debug. |
| Scheduler push or worker pull ambiguity | Make it **worker pull** by `lease_owner` (scheduler only claims) | Avoids “scheduler can’t reach workers” inflight dead-time; adds one DB read per job start (often acceptable). |
| `tenant_state.next_ready_at` maintained by app logic | Maintain it with a single, well-audited DB function/trigger *or* accept periodic recompute per tenant when it looks stale | Triggers add hidden complexity; periodic recompute adds occasional extra queries but is easier to reason about during incidents. |
| Per-job heartbeats for all jobs | Heartbeat only for jobs exceeding a runtime threshold; otherwise use conservative `lease_ttl` | Reduces write amplification; increases duplicate risk for truly-long jobs if thresholds are wrong. |
| One `jobs` table for everything (ready/leased/done/dead) | Keep hot states in the main table; **archive** `done/dead` to colder tables/partitions | More operational plumbing; keeps indexes small and vacuum predictable at 50M+ rows. |
| Custom queueing semantics from scratch | Evaluate `graphile-worker`, `pg-boss`, or `pgmq` as a baseline | Likely won’t meet tenant-first fairness out of the box; can still borrow proven patterns (schema, retry semantics, maintenance jobs). |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: implicit (DB is source of truth); enqueue/dispatch halt.
   - Recommendation: Strengthen — explicitly define API behavior (503 vs buffering), client retry guidance, and “recovery mode” (jittered scheduler ramp-up, backlog draining, per-tenant fairness preserved).

2. **Network partition: scheduler can’t reach workers (or workers can’t reach scheduler)**
   - Design’s answer: not addressed (handoff path is ambiguous).
   - Recommendation: Strengthen — pick worker-pull or ensure push failures don’t strand inflight (short lease TTL until a worker “ack-starts”, then extend).

3. **Worker crashes mid-job; lease expires; job is retried while side effects already happened**
   - Design’s answer: “require idempotency keys / downstream dedupe,” but enforcement is hand-wavy.
   - Recommendation: Must fix — define the concrete idempotency mechanism (DB idempotency table with unique `(tenant_id, idempotency_key)` + “record-before-side-effect” transaction, or strict requirements on downstream systems). Also specify what happens when idempotency storage is unavailable.

4. **`tenant_state.inflight` drifts (missed decrement, double decrement, reaper races)**
   - Design’s answer: mentions reaper but not invariants or reconciliation.
   - Recommendation: Must fix — state invariants and add a periodic reconciler (per-tenant) to correct inflight from leased rows (bounded by tenant), plus ensure reaper and dispatcher share the same per-tenant serialization primitive.

5. **10x traffic spike + large ready backlog (1M ready, 50M pending)**
   - Design’s answer: partially (partitioning, jittered polling, batch sizing).
   - Recommendation: Strengthen — call out DB write amplification hotspots (heartbeats, `tenant_state` updates, retry churn), connection pooling strategy, and an explicit “degraded mode” (larger batches, reduced fairness precision, rate-limit updates less frequently).

## Recommendations

### Must Fix
- Specify the exact **idempotency enforcement** (schema + when it’s written relative to side effects + failure behavior).
- Make `tenant_state` correctness explicit: invariants, serialization method (row lock vs advisory lock), and a bounded **reconciliation** path for `inflight` and `next_ready_at`.
- Decide the **handoff model** (worker pull is usually the simplest) and ensure leases don’t strand capacity when that channel is impaired.

### Should Consider
- Reduce DB hot writes: conditional heartbeats, batching lease extensions, and minimizing `tenant_state` writes (e.g., update tokens per claim batch, not per job).
- Archive cold states (`done/dead`) so “ready selection” indexes stay small and vacuum stays predictable.
- Start with a simpler fairness policy and explicitly gate DRR/weights behind observed need; keep the first production version debuggable at 3am.

### Nice to Have
- `LISTEN/NOTIFY` (or a lightweight wakeup channel) when a tenant transitions to “ready” to reduce polling—used sparingly (coalesced) to avoid notification storms.
- Operator safety rails: per-tenant pause/drain with TTL, replay tooling with rate caps, and “kill switch” defaults for bad configs.
- Clear SLO dashboards per tenant: time-to-dispatch, lease churn, retry storm detection by job signature.

## What’s Working Well
- The tenant-first admission framing is the right abstraction for noisy-neighbor control; it keeps the interesting part (fairness) separate from the boring part (durable state).
- You’re honest about at-least-once and push idempotency as the correctness strategy—this avoids the most common design lie in schedulers.
- The design anticipates saturation behavior (poll jitter, caps, DLQ, retry storms) and treats observability as a first-class requirement, which is exactly what makes systems like this operable.