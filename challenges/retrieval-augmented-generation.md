## Elegance Check

### The Core Insight
Treat “freshness” as a query constraint with an explicit, auditable contract (`change_seq`/`indexed_seq` + `write_token`), instead of trying to coerce an eventually-consistent vector index into behaving like a transactional database.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Postgres metadata + `change_seq` | Single source of truth for versions/ACLs/watermarks; debuggable correctness. |
| Versioned chunks + `model_id` | Prevents split-brain retrieval and embedding-space mixing during upgrades. |
| Async ingest/embed pipeline | Throughput/cost control for the 200M chunk bulk index and backfills. |
| Query-time merge + filters | Only place you can reliably enforce “latest version + correct model + ACL”. |
| “Recent changes” index (concept) | The only robust way to make read-after-write independent of async lag. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom in-memory FAISS/HNSW service with WAL for `Recent Index` | Use a managed store for the hot tier: (a) a second collection/namespace in the same vector DB, (b) Redis/RediSearch vector index, or (c) Postgres `pgvector` for “last N minutes” | Less bespoke ops; may cost more and/or have lower recall/throughput vs hand-tuned FAISS. |
| Global `change_seq` watermark | Per-tenant (or per-namespace) sequences stored in Postgres; publish per-tenant `indexed_seq` | Avoids global contention and head-of-line blocking; slightly more bookkeeping. |
| “Remove from Recent Index when indexed” based on advancing `indexed_seq` | Track per-document (or per-chunk-batch) “indexed” acknowledgements; only evict hot entries once that doc_version is fully present in main | More state, but avoids correctness gaps where `indexed_seq` advances while some chunks are missing. |
| Strict read-after-write depends on Recent Index availability | Make RA-W satisfiable by durable storage: write embeddings to Postgres/Redis first, then replicate into hot ANN; retrieval can fall back to exact/limited scan for that doc_id when hot ANN is down | Higher tail latency in degraded mode, but avoids hard “freshness error” for interactive users. |
| ACL filtering only at retrieval time | Pre-partition indexes by tenant/namespace (and maybe coarse ACL groups) so ANN search never considers obviously-ineligible chunks | More partitions/indexes to manage; much better latency/cost predictability at 2k QPS. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: not addressed (Postgres is the write-path truth + seq generator).
   - Recommendation: Strengthen (define write behavior: reject writes vs accept into a durable queue; define read behavior/caching and how `write_token` is issued).

2. **Recent Index is slow (not down), causing synchronous write latency spikes**
   - Design’s answer: not addressed (only covers outage).
   - Recommendation: Strengthen (add admission control: max doc size for sync path, per-tenant rate limits, “async write with explicit freshness_pending status”, and SLOs for write p95).

3. **Network partition between RAG API and Recent Index**
   - Design’s answer: “fail closed for strict read-after-write”.
   - Recommendation: Acceptable for correctness, but add a degraded fallback for the specific doc in `write_token` (fetch chunk text by doc_id/version directly; optionally run exact embedding match or bypass retrieval with “pinned doc context” for that user).

4. **Async pipeline processes out-of-order / duplicates / partial failures**
   - Design’s answer: implied via idempotent upserts, but not specified.
   - Recommendation: Strengthen (define event IDs, idempotency keys, per-doc “complete” markers, and how you prevent `indexed_seq` from advancing past missing work).

5. **Hot tier growth during backlog exceeds memory/TTL policy**
   - Design’s answer: “never silently drop; reject bulk imports or relax freshness”.
   - Recommendation: Strengthen (make the policy mechanical: per-tenant budgets, backpressure signals to writers, and an explicit “freshness class” so imports can degrade without impacting interactive RA-W).

## Recommendations

### Must Fix
- Define the **durable correctness point** for eviction: don’t evict hot entries based solely on a global `indexed_seq`; require per-doc/per-version completeness or you risk freshness gaps.
- Specify **idempotency + ordering** in the pipeline (event IDs, dedupe, replay semantics, and how to handle partial chunk failures).
- Add a **write-path latency budget and admission control** for sync embedding (max doc/chunk delta size, per-tenant rate limits, and an explicit degraded mode).

### Should Consider
- Replace the bespoke `Recent Index` service with a **managed hot index** (second collection in vector DB, Redis vector, or `pgvector` for recent-only) unless you have a clear SLO/cost reason to own FAISS+WAL.
- Partition watermarks by tenant/namespace to avoid global coupling and simplify multi-tenant isolation.
- Add an API affordance for the user intent behind RA-W: **“pin/include doc_id(s)”** (or “must-use write_token doc”) so correctness doesn’t depend on the ANN recall of a freshly embedded doc.

### Nice to Have
- A documented **degraded-read playbook** (what clients should do on freshness errors; retry/backoff; UI messaging).
- A clear **model rollout contract** (dual-write duration, cutover criteria, and how queries choose `model_id` during migration).
- Operational SLO dashboards that tie `vector_index_lag` and hot-tier pressure to **user-visible freshness compliance**.

## What's Working Well
- The design is honest that strong consistency in vector search is the wrong battle; the “freshness layer” is a clean abstraction.
- Sequence-number watermarks + versioned chunks make correctness debuggable (you can explain *why* a chunk appeared).
- Failing closed for strict RA-W is the right default for trust; you’re not hiding staleness behind “best effort”.
- The hot/cold split keeps the interesting part (freshness) bounded, and lets the bulk index stay cost-optimized.