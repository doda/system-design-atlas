## Elegance Check

### The Core Insight
Treating **time as a hard physical boundary** (immutable, time-windowed segments) is the right “TSDB-native” move: it makes retention a delete-by-drop operation and lets rollups be a streaming rewrite over already-ordered data.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| `WAL + Memtable` | Survives crashes while keeping ingest sequential and fast. |
| `Segment Store` | Immutable segments are the foundation for predictable retention + range scans. |
| `Compactor` | Without bounded compaction, you’ll get read amplification and disk-pressure death spirals. |
| `Series dictionary (series_key → series_id)` | Essential to avoid paying tagset cost per point at 50M series. |
| `Tag inverted index (tag → series_ids)` | Makes tag filters feasible without scanning. |
| `Rollup Builder/Store` | Keeps query p95 predictable by avoiding query-time downsampling tax. |
| `Router` | Decouples ingest API from shard placement and enables rebalancing. |
| `Query Engine` | Needed to plan “tag-filter → series set → time scans → aggregate”. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom segment store + compaction logic | Use an embedded LSM (`RocksDB`/`Pebble`) for raw+rollup storage, still time-partitioned at the directory/key-prefix level | Less control over TSDB-specific compaction/IO isolation; easier correctness/ops. |
| Custom router membership + shard ownership (implied) | Use `etcd` for membership + consistent-hash ring + shard leases | Adds dependency, but massively simplifies coordination and failure recovery. |
| Custom rollup pipeline (compacted segments → rollups) | Use a durable log (`Kafka`/`Pulsar`) to feed rollups and allow replay | More infra; but simplifies backfill, reprocessing, and “bad rollup code” recovery. |
| Custom tag index persistence strategy (implied) | Put series dictionary + tag index in `Postgres` (partitioned tables + GIN/JSONB) up to a cap; spill to custom only if needed | Might not hit 50M active series at required QPS; but can bootstrap MVP/early scale faster. |
| Building a TSDB from scratch | Adopt/extend an existing engine (VictoriaMetrics/M3/ClickHouse for metrics-like workloads) | Less “custom elegance”, but huge reduction in correctness + on-call surface area. |

## Stress Test

### Failure Scenarios

1. **Storage node dies mid-ingest**
   - Design’s answer: not addressed (WAL exists, but replication/HA semantics aren’t specified)
   - Recommendation: Strengthen (define replication factor, write quorum/ack level, WAL replay, and shard failover/lease handoff)

2. **Database down for 5 minutes (metadata/index path)**
   - Design’s answer: not addressed (series dictionary + inverted index are critical-path for both ingest and query)
   - Recommendation: Strengthen (define “metadata availability mode”: cache-on-router, local snapshots, and what happens on cache miss; otherwise ingest halts)

3. **Network partition between Router and storage nodes**
   - Design’s answer: partially addressed (stateless router, throttling), but no consistency model
   - Recommendation: Strengthen (explicit backpressure + retry policy, idempotency keys, and “at-least-once with bounded dup” mechanics across partitions)

4. **Compactor falls behind during 10x burst**
   - Design’s answer: addressed (budgets, priority, throttling ingest, pause rollups)
   - Recommendation: Acceptable, but add a hard safety valve (admission control tied to disk watermark + compaction lag to prevent total disk exhaustion)

5. **Bad rollup code/config deployed (wrong windowing, double-count, wrong p95)**
   - Design’s answer: not addressed (observability mentioned, but no rollback/rebuild story)
   - Recommendation: Strengthen (make rollups replayable: version rollup schemas, write rollup “generation id”, support rebuild from raw/compacted segments, and safe cutover)

## Recommendations

### Must Fix
- Specify **replication + durability semantics** end-to-end: RF, quorum vs primary-replica, write ack, and how queries behave during failover.
- Define the **series dictionary / tag index persistence and recovery** path: snapshots, rebuild time, and what ingest does on “new series” when the index is unavailable.
- Make **query fanout and series-set explosion** a first-class limit: cap matched series, cap group-by cardinality, and provide partial results/error modes.

### Should Consider
- Use `etcd` (or similar) for **shard leases/ring membership** to simplify safe rebalancing and avoid split-brain shard ownership.
- Make rollups **replayable and versioned** to handle operator mistakes without manual forensics.
- Clarify the **late data model**: how late segments merge, how queries avoid double-reading late+main, and what correctness you guarantee around the cutoff.

### Nice to Have
- Add a “**degraded modes**” section: what still works when compaction is paused, when index is stale, or when rollups lag.
- Document IO isolation concretely (cgroups/ionice/io_uring priorities, separate disks, or explicit bandwidth limits) rather than “separate threadpools”.

## What’s Working Well
- The design correctly centers **compaction as the heartbeat** and ties it to operator-facing signals (lag, disk watermarks, read amplification).
- The “consume **compacted** segments for rollups” insight is operationally clean and avoids subtle correctness traps.
- You’re honest about cardinality and explicitly include **admission control hooks** (limits, reject rules, throttling), which is where TSDBs usually fail in real life.