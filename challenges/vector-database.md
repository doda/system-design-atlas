## Elegance Check

### The Core Insight
Treating ANN indexing like an LSM: immutable per-segment ANN + background compaction, so the write path stays append-only and predictable while “index quality” becomes a compaction concern instead of a constant online rebuild problem.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| WAL + Memtable | Makes writes durable and cheap; gives you a single mutable truth and a clean boundary for recovery/replay. |
| Immutable Segments | Enables stable query latency under writes, efficient recovery/rebalance, and bounded mutation surface area. |
| Filter Indexes (bitmaps/inverted) | Makes selective filters a first-class pruning step instead of a latency roulette wheel. |
| Compaction | Prevents unbounded segment fanout and fixes update/delete debt (dedupe + tombstones) to keep recall/latency stable. |
| Query Router (timeouts/merge) | Central place to enforce tail-latency controls, hedging, fanout limits, and per-tenant fairness. |
| Catalog/Coordinator | Prevents split-brain ownership and gives an auditable source of truth for placement/config. |
| Object Store (segment blobs) | Simplifies shard recovery and rebalancing by turning data movement into “fetch blobs + verify hash.” |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “LSM-like vector store” from scratch | Build on Lucene/Tantivy segment model (HNSW + doc values + live docs) or adopt an existing vector DB (Qdrant/Milvus) and focus on your differentiator (multi-tenant + filters + ops) | Less control over low-level layout; faster time-to-correctness and fewer bespoke failure modes. |
| etcd + Postgres split control plane | Start with Postgres only (schema + shard map + leases via advisory locks + `LISTEN/NOTIFY`) | Postgres becomes more critical; etcd can still be introduced if/when you hit coordination latency or operational boundaries. |
| Separate Ingest API + Segment Builder | Co-locate ingest + flush/segment build on shard nodes (ingest routes directly to owning shard) | Shard nodes do more work; removes an entire hop/service and reduces “who owns the WAL?” ambiguity. |
| “latest-version map in RocksDB” + tombstones | Adopt Lucene-style “live docs” bitsets per segment + versioned IDs, where updates/deletes flip bits in a small mutable overlay | Requires careful overlay management; tends to be simpler and faster than per-candidate RocksDB lookups. |
| Bitmap construction per query per segment | Cache compiled filter plans and precompute common predicates (e.g., tenant) as reusable bitsets; consider per-tenant segment partitioning | More memory/caching complexity; reduces CPU spikes from repeated bitmap ops at high QPS. |
| Object store as primary for all segments | Start with local NVMe as primary + replicate segments to peers; add object store as cold backup/rehydration later | Recovery/rebalance becomes peer-dependent; you remove an external dependency from the hot path early on. |

## Stress Test

### Failure Scenarios

1. **Object store is slow/down for 5 minutes**
   - Design’s answer: not addressed (object store is on the query diagram path via shard nodes)
   - Recommendation: Strengthen — ensure queries never require object-store reads on the hot path (pin active segments locally); define behavior for cache miss (serve partial, fail fast, or block) and add prefetch on placement changes.

2. **etcd quorum loss / network partition**
   - Design’s answer: addressed (epochs + shards reject stale epochs; routers refresh)
   - Recommendation: Strengthen — specify the “safe default” during ambiguity (prefer unavailability over split-brain), and define how routers behave if coordinator is unreachable (serve from last-known-good for N seconds with strict epoch checks, then shed).

3. **DB (Postgres) down during deploy or config push**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — define a config caching/versioning story: shard/query router should run on last-known-good configs; rollouts should be monotonic (config version numbers) with an easy rollback path.

4. **Compaction falls behind + write spike (50k/s → 5 minutes)**
   - Design’s answer: partially addressed (metrics + throttle + workers + max-segment policy)
   - Recommendation: Strengthen — add a hard admission controller tied to “read amplification budget” (max segments searched per query) and define deterministic degradation (e.g., temporarily reduce recall via lower `efSearch` or cap segments searched + return “degraded” flag).

5. **High-cardinality / per-user ACL filter (worst-case selectivity <0.1%)**
   - Design’s answer: implied by bitmaps, but not realistic for per-user ACL unless you store enormous bitmaps
   - Recommendation: Strengthen — explicitly constrain supported filter shapes (e.g., ACL via precomputed groups/roles, or external authorization + tenant partitioning). Otherwise this becomes the hidden cost center.

## Recommendations

### Must Fix
- Define replication + consistency for writes: where the WAL lives, how many copies, what “durable ack” means, and how last-write-wins is implemented (timestamps? seqno per `(collection,id)`?) under retries and clock skew.
- Make “live docs” semantics explicit: how deletes/updates prevent stale hits without per-candidate RocksDB lookups becoming a p99 tax; how this interacts with gated HNSW expansion.
- Remove object store from the query hot path: shards should serve from local disks/mmap; object store is for bootstrap/rehydration, not on-demand fetch during query.
- Specify compaction correctness and scheduling: tiered vs leveled, target segment size, max fanout searched, and how you prevent synchronized IO storms across the cluster.

### Should Consider
- Lean harder into an existing segment/index engine (Lucene/Tantivy patterns) to reduce bespoke complexity: segments + live docs + doc values + HNSW is already the shape you’re reinventing.
- Tighten the filter model: document which predicates are “indexed-fast,” which fall back to scan, and what SLO impact each path has.
- Add explicit “degraded mode” behaviors (bounded work): caps on segments, caps on candidate budgets, and tenant-level fairness that is predictable under overload.

### Nice to Have
- Adaptive `candidate_budget`/`efSearch` based on filter selectivity estimates and recent recall SLO signals (automatic “spend more only when needed”).
- A clear “one person at 3am” playbook: which knobs to turn first (ingest throttle, compaction pause, segment cap, tenant isolation), and what metrics confirm recovery.

## What’s Working Well
- The LSM-segment framing is a clean way to make writes boring and to turn “index health” into a background maintenance problem with measurable budgets.
- Filter-first gating + explicit scan fallback is honest about the selective-filter edge case and gives you a deterministic escape hatch instead of tail-latency surprises.
- Calling out recall as an SLO and proposing shadow evaluation is exactly the right posture for ANN systems, where silent regressions are the real production risk.