## Elegance Check

### The Core Insight
Treat the home feed as a **cache of candidates** (inbox) backed by a **durable per-author outbox**, then bound worst-case cost with an explicit rule: **push for normal authors + pull for celebrities**, and only **materialize for active readers**.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Outbox Store | Single durable stream for rebuilds, pulls, and recovery; keeps truth simple. |
| Timeline Store (Inbox) | Buys low p95 for active readers and isolates read latency from follow graph size. |
| Fanout Workers | Moves expensive fanout off the request path; lets you apply backpressure and prioritization. |
| Social Graph | Required for follower expansion + follow/unfollow correctness; can’t “just infer” from posts. |
| Kafka (or equivalent) | Spike absorption + replay to rebuild/repair; decouples write path from fanout capacity. |
| Redis/CDN caches | The cheapest way to survive celebrity herd behavior and hot first-page reads. |
| Feed Service | Owns merge/dedupe/filter/ranking budgets in one place (critical for operability). |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate “Outbox Store” + “Timeline Store” described as distinct systems | Use one Cassandra/Scylla cluster + two table schemas (outbox/inbox) with shared ops/tooling | Fewer moving parts, but shared blast radius and capacity coupling. |
| Page token includes cursors for “each celebrity outbox” | Cap celebrities considered per page (top K by affinity/recency) or introduce a per-user “celebrity aggregate” stream updated every few seconds | Loses “complete” celebrity coverage, but prevents token bloat and worst-case fanout-on-read. |
| Unfollow handled by “edge epoch” + read-time filtering | Stamp `follow_epoch` onto inbox entries at write-time and compare to current epoch for only the authors present in the page (plus cache epochs in Redis) | Still needs lookups, but bounded and avoids scanning/rewrites; clearer correctness story. |
| Inactive readers served by merging many followed outboxes | Keep a small “lazy inbox” for everyone (filled on-demand via background job triggered by first read) | More storage/writes, but removes worst-case multi-merge for cold users and simplifies SLOs. |
| Compaction job deletes old unfollowed inbox entries | Prefer time-bucketed inbox partitions + TTL for old data; avoid mass deletes/tombstone storms | Slightly more complex schema, much safer Cassandra operations. |

## Stress Test

### Failure Scenarios

1. **Kafka is down / unreachable for 5 minutes**
   - Design’s answer: backlog/lag handling is discussed, but assumes Kafka is available enough to ingest.
   - Recommendation: **Strengthen** — use a transactional outbox pattern in Postgres (`posts` + `post_events`) so PostCreated is durable even if Kafka is down; replay when recovered.

2. **Social Graph is slow (not failing)**
   - Design’s answer: not addressed (fanout and read filtering both depend on it).
   - Recommendation: **Strengthen** — add explicit “graph-degraded mode”: serve from inbox/outboxes with cached follower/celebrity lists and skip expensive per-edge checks beyond a strict budget; alert on “graph budget exceeded”.

3. **Bad config / tier flapping (author toggles normal↔celebrity)**
   - Design’s answer: not addressed.
   - Recommendation: **Must fix** — add hysteresis + cooldown windows, and treat tiering as a versioned decision (so workers and readers agree); otherwise you get duplicate paths, missing content, and hard-to-debug incidents.

4. **Privacy/block/delete changes after fanout**
   - Design’s answer: mentions filtering on read, but the mechanics and indexes aren’t specified.
   - Recommendation: **Strengthen** — define a “visibility contract”: what is enforced at write-time vs read-time, how block lists are cached, and how deletes are represented (tombstone stream or post-status lookup) to avoid leaking content under cache.

5. **Timeline Store shard outage + celebrity herd at the same time**
   - Design’s answer: degrade to pull-from-outboxes; cache celebrity heads.
   - Recommendation: **Acceptable with guardrails** — ensure the degraded mode has hard per-request budgets (max outbox sources, max items fetched, max filter lookups) so an outage doesn’t amplify into a full-region thundering herd.

## Recommendations

### Must Fix
- Token and merge worst-cases: cap per-request celebrity sources and bound token size (`K`, max bytes), with a defined fallback when exceeded.
- Correctness around follow/unfollow: avoid relying on timestamps alone (clock skew); use server-assigned monotonic IDs/epochs and specify the exact rule for inclusion.
- Cassandra ops realism: design inbox partitions (time-bucket + TTL) to prevent tombstone/compaction incidents from unfollow cleanup.

### Should Consider
- Make Kafka optional at write time via transactional outbox in Postgres for survivability and simpler recovery.
- Add tiering hysteresis + versioning; treat tier decisions as data, not config.
- Define explicit budgets/SLOs per dependency (graph lookups, post-status checks, outbox reads) and enforce them in code.

### Nice to Have
- A single “degrade playbook” that spells out what gets dropped first (ranking → celebrity coverage → backfills) and how to safely restore.
- Canary + config rollout strategy for thresholds and caching knobs.

## What’s Working Well
- Clear separation of truth (outbox) vs performance cache (inbox) makes recovery and reasoning much easier.
- The “work placement” framing is the right center of gravity; ranking is correctly treated as a bounded, later-stage concern.
- Failure modes are acknowledged with pragmatic degradation paths; you’re already thinking like on-call.