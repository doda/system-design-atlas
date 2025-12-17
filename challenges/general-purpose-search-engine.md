## Elegance Check

### The Core Insight
Treat indexing as a deterministic log → immutable segment pipeline, so “correctness” comes from replay + segment lifecycle (adds/deletes/merges) rather than fragile in-place mutation.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Fetch Log (Kafka) | Gives you replay, auditability, and controlled reprocessing after bad tokenizer/canonicalization changes. |
| Raw Store (object storage) | The escape hatch for re-tokenization/spam fixes without re-crawling the web. |
| Segment Builder + immutable segments | Makes indexing idempotent and operationally recoverable; merge is the only mutating operation. |
| Index Shards on SSD | Required for p95 < 200ms at 50k QPS with BM25-style retrieval. |
| Two-stage ranking | Preserves latency/recall trade-off while enabling richer ML features. |
| Identity/dedup (DocID/ContentID) | Prevents duplicate explosion and keeps rank signals attached to the “right” entity. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom crawler + scheduler | Start with proven crawler (Heritrix/Nutch) + a thin policy layer; or outsource crawl (Common Crawl-like ingestion) | Less bespoke freshness control; faster time-to-production. |
| “Fetch Log as sacred” via Kafka | Store fetch events as Parquet in object storage (lakehouse) + a small “cursor” stream; keep Kafka only for hot orchestration | Harder “tail replay” semantics; cheaper long-term retention and easier backfills. |
| Near-dup “signature index per shard” in the online indexing path | Batch near-dup clustering (Spark/Beam) + emit alias maps; keep online path exact-dedup only | Slower near-dup convergence; big reduction in online complexity and paging risk. |
| Canonical URL + rules for DocID | Treat canonical URL as a *signal*, not an authority; default to content/host authority scoring and only promote canonical when trusted | More logic in quality scoring; less susceptibility to canonical-tag spam. |
| Shard fan-out for every query | Add aggressive caching layers: query→topK cache, “head terms” result cache, and shard-level term/postings cache | Cache invalidation/freshness complexity; major QPS and tail-latency relief. |
| Custom segment distribution/replication (implied) | Use object storage as the segment source of truth: shard nodes pull manifests + segments (content-addressed) | Slightly higher fetch latency on cold start; simpler recovery and replica bootstrap. |

## Stress Test

### Failure Scenarios
1. **Kafka down for 5 minutes**
   - Design's answer: partially addressed (lag + autoscale + replay), but assumes the log exists.
   - Recommendation: Strengthen — serving should be unaffected; indexing should degrade to “pause fetch ingest, continue crawl to raw store with later re-enqueue” or “pause crawling, preserve politeness state, resume safely.”

2. **Object storage degraded/unavailable**
   - Design's answer: not addressed (raw store is a hard dependency for rebuilds and likely for segment distribution).
   - Recommendation: Strengthen — make query path independent; for indexing, allow “tokenize from fetcher output” when raw-store write fails (with a clearly marked non-replayable mode) or buffer locally with bounded disk + backpressure.

3. **Network partition / slow shard (gray failure)**
   - Design's answer: addressed at a high level (time budgets, best-effort top-K).
   - Recommendation: Strengthen — specify concrete behaviors: per-shard deadlines, hedged requests, partial-result scoring normalization, and “skip shard” thresholds to avoid tail amplification and unstable ranking.

4. **Bad canonicalization/dedup deploy**
   - Design's answer: addressed (metrics, rollback, rebuild from raw store).
   - Recommendation: Strengthen — add a “shadow index” / dual-write canary for tokenizer versions and an automated “DocID churn” gate (if DocID reassignment spikes, block rollout).

5. **10x query traffic spike**
   - Design's answer: not addressed beyond time budgets.
   - Recommendation: Strengthen — caching + admission control + tiered degradation (reduce K, disable expensive features, drop rerank, return cached results) with explicit SLO-based switches.

## Recommendations

### Must Fix
- Define **sharding/routing invariants**: DocID (or stable routing key) must deterministically map updates/deletes/aliases to the same shard, or deletes become cross-shard coordination hell.
- Make canonicalization **adversary-aware**: canonical tags/redirect patterns are spam surfaces; treat them as weighted signals with trust/host reputation, not rules.
- Specify **segment manifest atomicity**: how you publish “new segments + delete bitmaps” without readers seeing torn state (e.g., versioned manifest + compare-and-swap in a coordinator/metadata log).

### Should Consider
- Move near-dup detection mostly **offline** (batch clustering) and keep the online pipeline deterministic and minimal.
- Introduce a **metadata/alias lookup** story explicitly (URL→DocID, DocID→current version, alias sets) and its availability requirements for serving/debuggability.
- Add explicit **degradation ladders** for ranking (BM25-only, smaller K, feature gating) to keep tail latency flat during incidents.

### Nice to Have
- Formalize “why” traces across both stages (BM25 term contributions + reranker feature attributions) and store them with sampled queries for on-call.
- Add “merge debt SLO” tied to tail latency, with automated merge throttling and emergency compaction playbooks.

## What's Working Well
- The replayable, immutable-segment pipeline is a clean operational core that scales with team maturity.
- The DocID/ContentID separation acknowledges the real-world identity problem (redirects, params, mirrors) instead of pretending URLs are entities.
- Two-stage ranking and explicit time budgets show good latency discipline; the design already thinks in “graceful degradation,” which is what makes search survivable in prod.