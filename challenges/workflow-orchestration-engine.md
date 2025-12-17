## Elegance Check

### The Core Insight
Treat each workflow as a single-writer, deterministic state machine whose *only durable truth* is an append-only history; everything else (dispatch, retries, visibility) is derived and therefore safely repeatable.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| History Store (append-only + version) | The only place you can enforce determinism, replay, and fencing/idempotent completion. |
| Orchestrator (single-writer per workflow) | Converts concurrency/split-brain into “extra work” via optimistic commits; keeps correctness local to `workflow_id`. |
| Transactional outbox + dispatcher | Bridges DB correctness to at-least-once messaging without coupling orchestration to Kafka availability. |
| Workers (external side effects) | Keeps engine pure; isolates business IO and lets retries/heartbeats be standardized. |
| Visibility Index (async) | Separates operational querying from correctness so search/load can’t wedge execution. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Kafka for both workflow tasks and activity tasks | Start with Postgres as the workflow-task queue (`SKIP LOCKED` + leases) and keep Kafka only for activity fanout | Less infra early; DB becomes hotter and you must design fair scheduling carefully. |
| Custom dispatcher service | Use Debezium CDC from outbox table to Kafka | Adds CDC operational complexity; reduces bespoke code and “mark sent” race handling. |
| Visibility Index as separate system | Postgres read model (materialized views / denormalized tables) fed from the same outbox | Simpler ops; may cap query flexibility/scale vs Elasticsearch/OpenSearch. |
| “Exactly-once effects” framed at engine level | Reframe as “exactly-once *acceptance* + at-least-once *execution*” with required idempotency contracts per activity type | More honest; pushes design docs to specify what’s guaranteed vs required from integrators. |
| Replay-only for state reconstruction | Add periodic snapshots (state + next_event_id) for long histories | More moving parts; dramatically improves p99 replay and reduces hot partitions. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: partially addressed (Kafka outage covered; DB outage not explicitly).
   - Recommendation: Strengthen. Define behavior for *all* APIs (start/signal/complete/poll), backpressure strategy, and recovery steps (replay storm control, dispatcher catch-up pacing).

2. **Network partition: workers can reach Kafka but not API/DB (or vice versa)**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen. Clarify that completion is authoritative only when committed to history; require workers to persist attempt state locally (or tolerate re-exec) and define retry/timeout semantics when completion can’t be reported.

3. **A “slow” component: visibility indexing or dispatcher lags for hours**
   - Design’s answer: addressed for Kafka lag/outbox backlog, but not the downstream effects (e.g., timer firing delays, user-facing “stuck” UX).
   - Recommendation: Strengthen. Add explicit SLOs and alerts tied to *workflow correctness risk* (e.g., “timers delayed > X”, “outbox age > Y”), plus degradations (pause new starts, shed load, prioritize timer/outbox drains).

4. **Bad deploy/config causes nondeterminism in workflow code**
   - Design’s answer: addressed (“fail fast with pointer”).
   - Recommendation: Strengthen. Add a versioning story: workflow code version markers, compatible change guidelines, and an operational playbook (rollback vs continue-as-new vs patch history).

5. **Traffic spikes 10x unexpectedly**
   - Design’s answer: partially addressed via sharding; replay cost and DB hotspots are implied.
   - Recommendation: Strengthen. Add admission control: cap concurrent workflow evaluations per shard, prioritize timers/heartbeats, and define what gets dropped/429’d first (starts vs signals vs list/search).

## Recommendations

### Must Fix
- Define the **timer subsystem** precisely: where timers live (DB rows?), how they wake orchestrators, how you prevent timer scans from becoming O(N), and what correctness means during outages (late is OK; early must be impossible).
- Tighten the **completion transaction contract**: exactly which row(s) are locked/checked (activity state + expected token), what isolation level assumptions exist, and how you avoid races between retry scheduling and late completions.
- Make the “exactly-once” claim explicit: guarantee **exactly-once state transitions/acceptance**, require **idempotency for side effects**, and document the failure mode when downstream lacks it (quarantine/manual reconcile is good—make it a first-class workflow state).

### Should Consider
- Start simpler by collapsing workflow-task scheduling into Postgres (at least initially) to reduce moving parts; keep Kafka focused on activity distribution if you need it.
- Add **snapshots/compaction** earlier than “100x”: your own p99 history of 10k events makes replay a primary latency driver at the stated decision QPS.
- Specify **hot workflow** handling: per-workflow rate limits, yielding/continuations, or splitting long workflows (continue-as-new) to avoid single-ID bottlenecks.

### Nice to Have
- Formalize **state machine invariants** (e.g., monotonic fence tokens, single completion) and add lightweight consistency checks/repair tooling.
- Add an explicit **backfill/rebuild** story for Visibility Index (from history/outbox) with bounded impact on production.
- Provide an operator “3am” runbook: “why stuck?” decision tree mapped to concrete metrics (outbox age, worker pollers, retry saturation, timer delay).

## What’s Working Well
- Clean separation of concerns: orchestration is pure/derivable; execution is external and fenced.
- The outbox pattern is used in the right place: correctness anchored in the DB transaction, messaging made repeatable.
- The single-writer-per-workflow model is the right elegance lever: it shrinks concurrency bugs into a single optimistic-commit boundary.
- Honest operational notes (payloads out of history, retention as reliability, stuck taxonomy) are exactly what makes these systems supportable.