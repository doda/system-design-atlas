## Elegance Check

### The Core Insight
Treating push sends as a **quota-governed scheduling problem** (not an HTTP relay) is the right abstraction; it turns provider slowness and tenant spikes into explicit, testable policy.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Kafka intents log | Durable intake + replay; clean separation of “accepted” vs “sent” semantics. |
| Scheduler policy (per shard) | The only truly custom logic: deterministic prioritization + fairness + quota enforcement under load. |
| Dispatcher (per provider) | Encapsulates provider-specific protocols, batching, and retry/error mapping. |
| Receipt stream | Makes status an append-only fact log (auditable, rebuildable) instead of a fragile in-place DB update. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate `Schedulers` and `Dispatchers` services | One “Broker Worker” binary: consume → schedule → dispatch (provider adapters as modules), still horizontally scaled by Kafka partitions | Less independent scaling, but fewer moving parts and simpler on-call. |
| Custom checkpointed in-memory token buckets to “fast KV” | Use Redis for rate limits (Lua token bucket / sliding window) or Redis Cluster with key hashing per tenant/campaign | Adds Redis dependency + network hop; buys simpler correctness and restart behavior. |
| Receipt Log as a distinct component | Make receipts a Kafka topic (append-only) + a **compacted** “latest-status” topic (or Kafka Streams materialized store) | Ties you closer to Kafka tooling; reduces bespoke state stores. |
| Quota allocation “across shards” for strict per-tenant global limits | Accept “soft global” limits (bounded drift) with Redis-backed global counters, while keeping shard-local fairness | Slightly less pure locality; dramatically simpler than dynamic shard quota allocation. |
| Partition key = `(tenant_id, destination_hash)` for parallelism + per-tenant accounting | Consider `(tenant_id)` for strict per-tenant quotas + a second-stage fanout/dispatch pool, or isolate only hot tenants into dedicated partitions | Reduces parallelism for hot tenants unless you add a split mechanism; improves quota correctness and explainability. |
| Weighted fair scheduling across tenants *and* priorities (DRR) per shard | Start with priority queues + per-tenant token buckets + simple round-robin among active tenants | Slightly weaker fairness under edge cases; easier to reason about and implement correctly. |

## Stress Test

### Failure Scenarios
1. **Kafka is unavailable for 5 minutes**
   - Design’s answer: not addressed (implicitly Kafka is core truth)
   - Recommendation: Strengthen (define ingress behavior: 503 vs local buffer with bounded disk; define “receipt gap” semantics; ensure producers have idempotent retry guidance)

2. **KV store for bucket checkpointing is down / slow**
   - Design’s answer: not addressed (checkpointing assumed available)
   - Recommendation: Strengthen (treat checkpointing as best-effort; on restart, rebuild buckets from Kafka events or fall back to conservative limits to avoid post-restart quota spikes)

3. **Network partition: Scheduler can read Kafka but can’t reach APNS/FCM**
   - Design’s answer: partially addressed (provider health shrinks bucket; retries)
   - Recommendation: Strengthen (explicit circuit breaker states per provider; ensure retries don’t explode Kafka/receipt volume; ensure `critical` has a bounded queue growth + clear “degraded” receipt)

4. **One component becomes slow, not failing (e.g., dispatch RTT p99 jumps, CPU throttling)**
   - Design’s answer: partially addressed (queue age as SLO signal)
   - Recommendation: Strengthen (define backpressure contracts: max in-flight per provider, per-tenant queue caps, and what gets dropped/429’d first; avoid hidden threadpool queueing)

5. **Bad config / policy deploy (wrong weights, bucket sizes, or “critical reserve” too high)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen (config versioning + canarying; “safe mode” defaults; runtime guardrails like min/max bucket bounds and automatic rollback on SLO regression)

## Recommendations

### Must Fix
- **Make quota correctness explicit:** “allocate tenant quota across shards” is the hardest operationally—spell out the exact algorithm, how it adapts to partition count changes/rebalances, and the worst-case drift during failures.
- **Define idempotency precisely:** broker-level dedupe storage/retention, memory sizing at 2M/sec, and provider-specific idempotency (APNS collapse-id, FCM keys) so “replay + retries” doesn’t silently multiply sends.
- **Clarify receipt semantics and gaps:** what’s guaranteed when Kafka lags, providers time out, or callbacks never arrive; document the state machine and when states are terminal.

### Should Consider
- **Reduce component count:** merge scheduler+dispatcher into one worker process (still logically separated) unless you truly need independent scaling and blast radius separation.
- **Use Kafka-native materialization for receipts:** append-only receipts + compacted latest-status topic (or Kafka Streams) to avoid a bespoke “queryable state” path.
- **Isolate `critical` at the transport layer:** a separate Kafka topic (or at least partitions/consumer group) for `critical` so “protection” isn’t purely an in-process scheduling promise under extreme lag.

### Nice to Have
- **Operator-focused controls:** per-tenant kill switch, per-campaign pause, and “degrade mode” that automatically converts `normal`→`bulk` for certain tenants during incidents.
- **Replay safety tooling:** a “replay with limits” tool that reprocesses Kafka safely (caps per-tenant/provider, emits audit receipts).

## What’s Working Well
- The design is honest that **prioritization + enforceable quotas** (not Kafka itself) is the real problem, and it puts the custom complexity in the scheduler where it belongs.
- Priority separation + queue-age-first observability is operationally mature and aligns with SLOs.
- Receipts modeled as facts (ENQUEUED/DISPATCHED/PROVIDER_ACCEPTED/DELIVERED/FAILED) avoids the most common push-system lie: conflating “accepted” with “delivered”.
- Treating provider capacity as a dynamic control signal (bucket contraction) is a clean, elegant way to avoid cascading failures.