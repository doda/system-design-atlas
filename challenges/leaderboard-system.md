## Elegance Check

### The Core Insight
Separating **durable truth (Kafka event log)** from **disposable, read-optimized materialized views (Redis/state stores)** is the right “make outages recoverable” move, and it keeps the design honest about what must be exact vs what can be approximate.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Kafka log | Replay/backfill/idempotent convergence; turns bad deploys into recoverable incidents |
| Stream processor | Central place to enforce update semantics + windowing + dedupe, and to materialize multiple read models |
| Redis serving (top-K, hot reads) | p95 read latency + heavy caching; isolates query load from processor state |
| Postgres (config + audit metadata) | Versioned leaderboard definitions, operational control plane, explainability hooks |
| Object storage (snapshots/checkpoints) | Fast rebuilds + immutable history for 90-day support/audit |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Flink + Redis + snapshots | Kafka Streams with RocksDB state + optional Redis only for top-N | Fewer moving parts, but “queryable state” ops/debuggability can be harder than Redis APIs |
| Per-shard ordered sets for everyone | Keep **only top-K (and maybe top-(K+buffer))** in Redis; store long-tail per-player score in processor state/DB | “Around me” becomes approximate or higher-latency; big reduction in Redis memory/ops |
| Periodic shard emits top-M | **Threshold-triggered** emits: processor publishes current global Kth score; shards emit any player crossing it | More coordination/topic traffic, but clearer correctness and faster promotion into top-K |
| Quantile sketches + “adjusted around-me” | Make percentile/tier first-class API (tiered ranks), drop implied exactness for long tail | Product/API change, but dramatically clearer semantics and less bespoke math |
| Event-time with allowed lateness | Server-receive-time only (and treat late client stamps as untrusted) | Loses some “true event-time” fidelity, but simpler and safer for games |

## Stress Test

### Failure Scenarios
1. **Kafka is down for 5 minutes**
   - Design’s answer: not explicitly addressed (assumes Kafka as source of truth)
   - Recommendation: Strengthen (define ingress behavior: reject vs buffer; max buffer; backpressure; what clients see)

2. **Redis cluster partial outage / eviction storm**
   - Design’s answer: rebuild from checkpoint + replay; degrade reads
   - Recommendation: Strengthen (explicit stale/fallback contract per endpoint; ensure top-K exactness story doesn’t silently degrade into wrong winners)

3. **Stream processor restart + state restore takes hours**
   - Design’s answer: mentions lag/backpressure, checkpoints
   - Recommendation: Strengthen (RTO/RPO targets, checkpoint frequency/size, and “serve from snapshots” mechanics for *active* windows, not just finalized)

4. **Hot leaderboard causes partition skew (one mode/region dominates)**
   - Design’s answer: partition by `(leaderboard_id, player_id)`; shards by `player_id`
   - Recommendation: Strengthen (skew still hits a subset of partitions; define partitioning strategy, hot-key detection, and a re-shard plan without breaking ordering/idempotency)

5. **Bad config deploy (tie-breaker/K/window policy changed)**
   - Design’s answer: “changes should version, not mutate”
   - Recommendation: Acceptable but specify (migration/backfill behavior, and how reads choose config version for an in-flight window)

## Recommendations

### Must Fix
- Define **freshness guarantees**: max “event accepted → visible” staleness, and what each endpoint returns under lag (especially “my rank” and “around me”).
- Make **global top-K correctness** explicit: either (a) accept bounded staleness, or (b) implement threshold-triggered promotion so “winner set” is actually exact under continuous updates.
- Revisit **Redis memory model**: per-shard ordered state for millions *per window per leaderboard* is likely the real scaling limiter; quantify it and narrow Redis to what must be fast.

### Should Consider
- Collapse complexity by choosing one primary serving plane: either “processor state is the store” (Kafka Streams interactive queries) or “Redis is the store” (but then be crisp about what’s stored and why).
- Make the long-tail UX explicitly **tier/percentile-based**, and stop implying global integer rank outside top-K.

### Nice to Have
- Operational “3am” tools: per-player explain endpoint (show events/versions applied), replay controls, and a safe kill-switch to shed non-critical computations (sketch updates, around-me).
- A clear reprocessing playbook: how to fix a bug in scoring logic and rebuild deterministically.

## What's Working Well
- The design is unusually clear about trade-offs (exactness where it matters, approximation where it doesn’t).
- Treating Redis as disposable + leaning on replayability is the right reliability posture.
- Windowing guidance (UTC alignment, pre-warm, finalize) and “visible freshness” as a first-class metric are exactly the right instincts.