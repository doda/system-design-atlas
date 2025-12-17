## Elegance Check

### The Core Insight
Treat authz as a **versioned snapshot query** with an explicit **revision contract** (`write -> revision`, `read(min_revision)`) so correctness and caching fall out naturally.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| MVCC tuple store (CockroachDB) | Makes “check at revision” a real, debuggable guarantee instead of a cache-invalidation guessing game |
| Check engine (memoized, batched) | ReBAC worst-cases are query-shape problems; you need controlled expansion, batching, and short-circuiting |
| Revision tokens in API | Turns consistency into an explicit product/API choice; enables read-your-writes without punishing all reads |
| Per-tenant quotas/limits | Authz is an attack surface; guardrails prevent one tenant/object from taking down the fleet |
| Watch (some form) | Required for operability: debugging, replication verification, and “what changed?” workflows |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Kafka log + Watch/Frontier service | Use **CockroachDB changefeeds** (resolved timestamps) to drive watch + frontier directly | Less generic pipeline than Kafka; ties you more tightly to CRDB primitives |
| Separate “Edge gRPC” + “Authz API” | Collapse into one service (or keep a standard Envoy edge and treat it as infrastructure) | Slightly less explicit separation; fewer moving parts for on-call |
| Redis cache keyed by exact `(tenant, revision, key)` | Cache primarily at the **stable frontier revision** (or a coarse “revision window”), keep per-request memoization for strict reads | Strict reads may benefit less from shared cache; needs careful correctness story for coarsening |
| Custom Zanzibar implementation | Consider **SpiceDB/OpenFGA** as a baseline (even if you still choose custom) | You inherit their constraints/opinions; but you buy years of edge-case hardening |
| Frontier “known queryable locally” as a bespoke concept | Align terminology/behavior with CRDB **follower reads / closed timestamps** | Might constrain how you model “stable”; but reduces bespoke consistency machinery |

## Stress Test

### Failure Scenarios

1. **CockroachDB unavailable for 5 minutes**
   - Design’s answer: not addressed (implicitly “checks hit tuple store if cache misses”)
   - Recommendation: **Strengthen** — define explicit behavior: return typed `UNAVAILABLE` (not “deny”), shed load early, and publish an on-call playbook (what degrades, what hard-fails, which clients retry).

2. **Kafka (or watch pipeline) is down but DB is up**
   - Design’s answer: cache correctness doesn’t depend on invalidation; frontier may stall and reads look stale
   - Recommendation: **Strengthen** — make “default stable revision” derivable from the DB (e.g., changefeed resolved timestamps / closed timestamp) so the watch pipeline failure doesn’t silently turn into “permissions didn’t apply”.

3. **Cross-region partition: writes succeed in Region A, reads happen in Region B**
   - Design’s answer: strict callers either wait for frontier or route to write region
   - Recommendation: **Strengthen** — specify the policy knobs: max-wait before error, when to route vs wait, and how clients learn the “home region” for a tenant to avoid surprise tail latency.

4. **Bad schema rollout (semantic change breaks checks or explodes expansions)**
   - Design’s answer: “validate offline, gate per tenant, keep old versions queryable”
   - Recommendation: **Strengthen** — add a hard “schema safety” contract: max expansion constraints enforced at compile-time, canary checks against recorded real queries, and a fast rollback path that doesn’t require tuple rewrites.

5. **10x read traffic + hot object stampede**
   - Design’s answer: singleflight/coalescing + prewarm + quotas
   - Recommendation: **Acceptable**, with one caveat: revision-keyed shared caching can thrash if revisions advance quickly; bias caching toward the stable frontier to keep keys reusable across requests.

## Recommendations

### Must Fix
- Clarify error semantics: “fail closed” vs “typed error” is contradictory; prefer **return errors** and let callers decide whether to treat authz `UNAVAILABLE` as deny for their risk model.
- Define strict-read behavior under lag: max wait, routing rules, and what token is returned on every response (`served_revision`) so clients can enforce monotonic reads safely.
- Address revision-key explosion: with high write rates, exact-revision Redis keys can become unbounded churn; constrain caching to stable frontier (or introduce a bounded revision window strategy).

### Should Consider
- Remove Kafka if it’s only there for watch/frontier/invalidation: CRDB changefeeds can cover most of this with fewer operational surfaces.
- Make tenancy/sharding concrete: how tenants map to CRDB ranges/partitions, and how noisy-neighbor isolation works beyond quotas (routing + physical locality).
- Add an explicit “consistency product matrix”: which user flows must pass `min_revision`, which must never block, and what UX you expect when strict reads can’t be satisfied.

### Nice to Have
- “Break-glass” tooling: immutable audit log of tuple writes, fast revert mechanism for accidental mass grants, and operator-safe bulk operations.
- Golden-query suite: a small set of representative checks/lookups that run continuously per region to catch frontier/caching regressions early.

## What’s Working Well
- The revision-token contract is the right center of gravity: it makes correctness explainable and testable.
- You treat graph blowups as a first-class reliability problem (limits, budgets, cycle handling) rather than an afterthought.
- Operational concerns are baked in (explain tooling, quotas, schema rollout), which is where most Zanzibar-like systems fail in practice.