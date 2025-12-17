## Elegance Check

### The Core Insight
Treating each “cron fire” as a durable, uniquely-identified object (`(job_id, scheduled_at)`) makes correctness independent of leader uptime; the leader becomes a replaceable *minting* process, not a single point of truth.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Postgres (`jobs`, `runs`) | Provides the atomic uniqueness guarantee and audit trail; enables deterministic catch-up after crashes. |
| Outbox table + publisher | Closes the “inserted but never enqueued / enqueued without durable record” gap. |
| Execution queue | Absorbs boundary spikes and decouples scheduling correctness from worker capacity. |
| Idempotent workers keyed by `run_id` | Converts duplicates into safe retries; keeps delivery at-least-once but effects controlled. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| etcd/Consul leader election | Postgres advisory lock (`pg_try_advisory_lock`) or “leader row” with lease timestamp | Removes an external dependency, but couples leadership to DB health (often acceptable since DB is already correctness-critical). |
| Separate scheduler + outbox publisher service | Single process with two loops (mint + publish) using `SKIP LOCKED` on outbox | Fewer deployables; need to ensure publish loop can’t starve mint loop under heavy backlog. |
| `jobs.next_fire_at` cursor | Compute next times from cron + last minted run (`MAX(scheduled_at)`) | Removes cursor correctness concerns, but adds aggregation pressure unless you keep per-job “last_minted_at” anyway. |
| Scan due jobs each tick | Use a bucketed index/table (minute bucket -> job ids) maintained on job updates | More moving parts, but reduces “WHERE next_fire_at <= now()” hotspots at aligned boundaries. |
| Kafka/SQS/RabbitMQ left open-ended | Start with Postgres-based queue (outbox is already there) + workers polling `run_outbox` | Simplifies infra for a small team; loses some queue ergonomics (consumer scaling, retention, tooling) and can increase DB load. |

## Stress Test

### Failure Scenarios

1. **Database down for 5 minutes**
   - Design’s answer: fail closed; catch-up deterministically after recovery
   - Recommendation: Strengthen — define explicit behavior for `catch_up` jobs during DB outage recovery (cap/priority) so “DB returns” doesn’t immediately become “queue/worker overload”, and document RPO/RTO expectations.

2. **Network partition: scheduler has etcd lease but can’t reach Postgres (or vice versa)**
   - Design’s answer: partially addressed (DB time, leader lease), but partition semantics aren’t spelled out
   - Recommendation: Strengthen — treat Postgres as the final arbiter: if DB unreachable, scheduler must stop minting regardless of lease; ensure lease renewal doesn’t imply ability to act.

3. **Queue outage for 10 minutes while DB is up**
   - Design’s answer: runs accumulate, outbox grows; resume publish later; optional pause minting
   - Recommendation: Strengthen — add a hard backpressure rule (“pause minting when outbox lag > X or table size > Y”) and a priority policy so “fresh” runs don’t get buried behind catch-up backlog.

4. **Slow component (DB is up but transactions take 3–10s)**
   - Design’s answer: not explicitly addressed beyond “detect latency”
   - Recommendation: Strengthen — ensure scheduling loop is set-based (batch insert) and uses `SELECT … FOR UPDATE SKIP LOCKED` on `jobs` to avoid head-of-line blocking; avoid per-job transactions at peak boundaries.

5. **Bad config / buggy cron parser deployed**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — add safety rails: validate cron/timezone on write, version cron evaluation logic, and have a “dry-run mint” mode or feature flag to stop minting without stopping publishing/execution.

## Recommendations

### Must Fix
- Define and enforce the invariant for advancing `jobs.next_fire_at`: update it in the same transaction as minting runs (or prove you don’t need it), otherwise you risk repeated scanning/lock contention and confusing “lag” signals.
- Make the concurrency model explicit: how multiple scheduler instances behave against `jobs` (locking strategy, `SKIP LOCKED`, batch size) so a leader swap can’t cause thundering-herd DB load.
- Specify worker idempotency semantics beyond “dedupe by `run_id`”: what is allowed to happen on retry, how side effects are made safe (e.g., downstream idempotency keys, exactly-once per external API).

### Should Consider
- Drop etcd/Consul if the team is small: Postgres advisory locks often give “good enough” leadership with fewer operational dependencies (and correctness already depends on Postgres).
- Prioritize “fresh ticks” over catch-up in the outbox/queue to keep latency SLOs meaningful during recovery.
- Add per-tenant quota + scheduling fairness at the minting stage (not only at worker stage) so one tenant can’t generate infinite run rows during downtime.

### Nice to Have
- Partition/TTL strategy spelled out for `runs` and `run_outbox` (including index choices) to keep P99 predictable at 30-day retention.
- Operational runbooks: “DB down”, “queue down”, “scheduler wedged”, “catch-up storm”, including the one command/button to pause minting safely.
- A clear policy for missed boundaries: how you round `scheduled_at`, timezone/DST behavior, and what “minute granularity” means during DST jumps.

## What’s Working Well
- The “exactly-once identity over exactly-once delivery” framing is the right mental model and keeps the design honest.
- Outbox is correctly identified as the linchpin that prevents the nastiest split-brain between DB state and queue state.
- Catch-up being explicit per job (skip vs capped) is pragmatic and prevents surprise storms.
- The design cleanly separates correctness (mint durable runs) from capacity (workers/queue), which makes failures diagnosable and recoverable.