## Elegance Check

### The Core Insight
Decoupling **candidate generation (fast, immutable-ish FST snapshots)** from **ranking (cheap, bounded, personalized deltas)** is the right shape: it keeps the online path deterministic while letting relevance evolve quickly.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Edge cache | Absorbs the “top few prefixes” firehose; cheapest p99 win. |
| Typeahead API | Normalization, budgets, safety checks, orchestration; keeps clients dumb. |
| Prefix index (FST) | Predictable latency and memory efficiency; avoids per-keystroke search-engine fanout. |
| Ranker | Where iteration happens; bounded compute keeps SLO honest. |
| User profile cache | Keeps personalization off critical storage; enables hard timeouts + graceful fallback. |
| Index builder + versioned store | Makes freshness safe (atomic swap/rollback) and operationally tractable. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate `Query Cache` for finals + candidates | Start with **only candidate caching** + edge cache for anonymous | Slightly higher CPU for logged-in users; fewer cache-invalidation paths. |
| Redis for profile + (maybe) Redis for candidates | Keep **profiles in Redis**, but store candidates in **process memory (TinyLFU)** per host | More per-host variance; needs warmup strategy and cache prefill for hot prefixes. |
| “Streaming + batch” builder | One **streaming pipeline + periodic full rebuild** (nightly) | Streaming job gets more responsibility; full rebuild still needed for correctness drift. |
| Custom snapshot distribution logic | Use **object store + signed manifest + CDN** for shard delivery | Less control over rollout pacing; relies on CDN semantics but reduces bespoke plumbing. |
| Per-user final caching via `user_cluster_id` | Make this an explicit phase-2; start with **no logged-in final caching** | Higher backend QPS; avoids subtle privacy/caching correctness issues early. |
| Complex coordination for swaps | If single region: **etcd/Consul** (or even S3 manifest + health gates) to coordinate versions | External dependency (etcd) or fewer guarantees (S3-only); but clearer ownership than ad-hoc coordination. |

## Stress Test

### Failure Scenarios

1. **Database/Redis is down for 5 minutes**
   - Design’s answer: profile cache outage → hard timeouts, no retries, degrade to generic.
   - Recommendation: Strengthen — also specify what happens if **candidate cache** is Redis-backed (serve stale, local LRU fallback, or skip cache entirely).

2. **Network partition / partial region outage**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen — define “regional autonomy”: local copies of last-good index + local caches; manifest rollout should be region-scoped with independent rollback.

3. **One component is slow but not failing (p99 creeps)**
   - Design’s answer: budgets and timeouts mentioned; no retries in hot path.
   - Recommendation: Strengthen — add explicit **load shedding** rules (cap candidates, skip profile fetch after X ms, drop to top-K global, and return fewer results rather than timing out).

4. **Bad index publish (relevance regression / corrupt shard)**
   - Design’s answer: canary load checks + online metrics + rollback via manifest pointer; keep N-2 locally.
   - Recommendation: Acceptable — add “semantic canary”: compare against previous version for top prefixes (diff threshold) before serving real traffic.

5. **Traffic 10× spike + cache stampede**
   - Design’s answer: coalescing, TTL jitter, serve stale.
   - Recommendation: Strengthen — ensure coalescing exists at **edge and origin**; add per-prefix singleflight + global circuit breaker to stop redistributing misses into backend collapse.

## Recommendations

### Must Fix
- Define multi-region behavior: where the FST lives, how manifests roll out, and what “last known good” means under partition.
- Make cache ownership explicit: if candidates are in Redis, spell out **stale-while-revalidate**, per-key singleflight, and what happens when Redis is impaired.
- Add safety/abuse controls: PII-sensitive prefixes, query suppression, rate limits, and “do not suggest” policy (autocomplete often leaks sensitive or policy-violating content).

### Should Consider
- Start simpler: edge cache (anonymous finals) + per-host candidate cache + bounded ranker; add Redis candidate caching only if needed.
- Treat “stability” as a first-class contract: define a measurable stability metric (e.g., Kendall tau / churn rate) and bake it into canary gates.
- Tighten the data contract between builder and ranker (feature schema/versioning) so index swaps can’t break serving.

### Nice to Have
- Offline evaluation loop: sampled request traces → replay against new index/ranker → score deltas before rollout.
- Explicit warmup plan: preload hot prefixes on deploy and on index swap to avoid cold-cache p99 spikes.
- Clarify language/normalization strategy (Unicode, tokenization, mixed scripts, diacritics) since it dominates real-world quality.

## What’s Working Well
- The “snapshot + atomic swap” approach is operationally clean and keeps tail latency predictable.
- Caching the **candidate list** (not the final personalized response) is the right reuse boundary and keeps personalization bounded.
- The design is honest about trade-offs (minutes-level freshness, capped personalization) and provides concrete mitigations (hard timeouts, rollback, coalescing).