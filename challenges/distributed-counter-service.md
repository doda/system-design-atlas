## Elegance Check

### The Core Insight
Model **likes as `(user_id,item_id)` state transitions** and only emit `+1/-1` on *actual* state change; it’s the cleanest way to get retry/dup/out-of-order tolerance without distributed transactions.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Kafka event log | Replay/backfill/audit + absorbs spikes better than OLTP writes |
| Stream processor (stateful) | The only sane place to enforce like-state semantics at scale |
| Read API + aggressive cache | 1–5M QPS needs a cheap, cacheable read path |
| Materialized counts store | Makes reads O(1) without summing shards per request |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate `Counter Shards` + `Compactor` + `Materialized Counts` | Collapse into **one sink**: the stream job maintains serving counts directly (per item / per bucket) and optionally keeps “shard” only for hot keys | Less flexibility to change striping post-hoc; stream app becomes more critical |
| “Views topic keyed by `item_id`” | Key views by `(item_id, random_shard)` or `(item_id, time_bucket, shard)` to avoid **Kafka partition hot-spotting** on viral items | Loses per-item ordering (not needed) and complicates downstream aggregation slightly |
| Raw view event log as system of record | For views, store **pre-aggregates** (edge/app batching) + optional sampled raw stream | Reduced audit granularity; definition of “view” becomes more product-y |
| External DB writes relying on Streams “EOS” | Keep EOS *within Kafka* and write counts via **idempotent sink** (upsert by `(item_id,bucket)` with version/sequence) or materialize counts into a compacted Kafka topic | External store still needs idempotency; compacted topic is great for durability but not for ultra-high-QPS reads alone |
| Infinite like state retention | On `UNLIKE`, **tombstone** state; optionally TTL old “unliked” | If a very old duplicate arrives after TTL, it might be misinterpreted unless you accept bounded dedupe windows |

## Stress Test

### Failure Scenarios
1. **Kafka is down for 5 minutes**
   - Design’s answer: partially addressed (“replay once stable”, throttle ingest)
   - Recommendation: **Strengthen** — define ingest behavior (buffer? reject? degrade views-only?) and SLO impact (“counts stale” is an outage). For likes, be explicit whether you accept writes when the log is unavailable.

2. **Viral item causes hot partition**
   - Design’s answer: addressed for shard store (“stripe factor”), but views topic keying can hot-spot Kafka itself
   - Recommendation: **Must fix** — shard *at Kafka partitioning layer* for views; otherwise the log/consumer becomes the bottleneck before your counter shards help.

3. **Stream processor restarts / rebalances under load**
   - Design’s answer: implied via Streams state store + changelog
   - Recommendation: **Strengthen** — call out restore time, standby replicas, and how you prevent long “counts frozen” during large state recovery (especially like-state RocksDB size).

4. **Aggregator → counter store network partition / slow writes**
   - Design’s answer: not addressed
   - Recommendation: **Strengthen** — specify backpressure strategy (pause consumption vs. buffer vs. drop views), and how you prevent unbounded lag/rockets in retry storms.

5. **Bad config / code deploy emits wrong deltas**
   - Design’s answer: addressed via reconciliation + backfill
   - Recommendation: **Acceptable** — add an explicit “versioned materialization” cutover plan (write v2 side-by-side, compare, then flip reads) so rollback doesn’t require heroics.

## Recommendations

### Must Fix
- Fix **views partitioning**: don’t key the views topic solely by `item_id`; shard at ingest so Kafka partitions don’t melt on hot items.
- Be honest about **EOS limits with external stores**: Streams EOS doesn’t make DB writes exactly-once; require idempotent sink semantics (sequence/versioned upserts) or keep “truth” in Kafka and rebuild deterministically.
- Address **like-state size**: `(user,item)` KTable can become massive; explicitly tombstone on unlike, plan state restore times, and document retention/TTL policy.

### Should Consider
- Collapse `Counter Shards` + `Compactor` if possible: let the stream job maintain serving counts directly (and only keep shard mechanics where they’re demonstrably needed).
- Define **degradation modes**: drop/shed views (best-effort) early; never drop likes, but be explicit about acceptance during partial outages.
- Make “staleness” first-class in the API (`last_updated_ts`, freshness SLO) so clients degrade gracefully.

### Nice to Have
- A “recompute pipeline” playbook: versioned topics/stores, validation gates, and automated cutover.
- Guardrails for operators: per-item hotspot dashboards, lag-to-staleness mapping, and “stop the bleeding” runbooks (pause consumers, switch to sampled views, etc.).

## What's Working Well
- Clear separation of **write durability (log)** from **read serving (materialized counts)**.
- The like state machine is the right correctness boundary: simple, deterministic, and naturally idempotent.
- You already treat **reconciliation/backfill as mandatory**, which is the difference between “event-sourced” and “we have Kafka”.