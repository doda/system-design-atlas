## Elegance Check

### The Core Insight
Versioned, per-user adjacency “snapshots” turn cache invalidation into a tiny metadata bump, making staleness safe and reasoning/ops dramatically simpler under read-heavy load.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Relationship API | Centralizes semantics (follow/block), idempotency, pagination, and coalescing/serve-stale behavior. |
| Postgres | Transactional source of truth; enforces uniqueness and consistent pagination order. |
| Redis | Makes hot list pages and point lookups predictably low-latency; absorbs read peaks. |
| Repair/Reconcile (some form) | Necessary if you keep dual materialized representations or depend on “eventual repair” as a safety net. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Two physical tables: `following_by_src` + `followers_by_dst` | Single `edges` table with two indexes (`(src, created_at, dst)` and `(dst, created_at, src)`), plus partitioning | Potentially heavier index maintenance; but removes an entire class of forward/reverse divergence and repair logic. |
| Versions stored “can be in Redis” | Store versions in Postgres transactionally (`user_relation_versions`), optionally cached in Redis | Slightly more DB work per write, but eliminates version loss/regression and “DB commit succeeded but version bump failed” staleness. |
| Event Log + Replay Worker as first-class services | Postgres outbox table + periodic reconciler (or logical decoding later) | Less real-time replay flexibility early; far simpler operational footprint for a small team. |
| Redis singleflight locks per `following:{u}:v{n}` | In-process request coalescing per API instance + bounded Redis lock only for the hottest keys | Coalescing doesn’t help across instances; but reduces Redis coordination complexity and lock contention. |
| “Bump versions on every write request” | Bump only on state change (conditional bump based on `INSERT ... ON CONFLICT DO NOTHING` / affected rows) | Slightly more write-path branching; avoids version churn and cache trashing under retries. |

## Stress Test

### Failure Scenarios

1. **Postgres down for 5 minutes**
   - Design's answer: partially addressed (Redis outage discussed; DB outage not explicitly)
   - Recommendation: Strengthen — define explicit degradation modes (serve-stale-only, disable cold fills, shed celebrity list endpoints), and a clear “what remains available” matrix.

2. **Redis loses data / restarts / flushes (versions reset)**
   - Design's answer: not addressed (Redis outage is, but not version regression)
   - Recommendation: Strengthen — prevent version going backwards (store version durably in Postgres or include an epoch component). A Redis reset + version reuse can make old cached snapshots reachable again.

3. **Write succeeds in Postgres, but version bump fails (Redis latency/timeout)**
   - Design's answer: hinted (“durable source can be Postgres”), but not specified as a correctness requirement
   - Recommendation: Must-fix — otherwise you can violate the freshness target indefinitely until TTL. Make the version bump part of the same durability domain as the edge change (transactional in Postgres), then treat Redis as a cache of the version.

4. **Network partition: API ↔ Redis slow (not down), Postgres healthy**
   - Design's answer: partially addressed (general cache latency/outage)
   - Recommendation: Strengthen — time-box Redis calls and fail open to DB with strict rate limits; otherwise “slow cache” is worse than “no cache” and can cascade into thread/connection pool exhaustion.

5. **Bad deploy / bug bumps wrong user’s version or emits wrong event**
   - Design's answer: not addressed directly
   - Recommendation: Strengthen — add invariant-based monitoring tied to the core idea (e.g., “version bump must correlate with an actual edge state change”, divergence sampling, and canarying config changes). Also define a “stop-the-world” switch for writes + a replay plan.

## Recommendations

### Must Fix
- Make version monotonic and durable (avoid Redis-only versions; avoid version regression after Redis restart).
- Bump versions only when the edge state actually changes (idempotent retries should not churn versions/caches).
- Clarify the write atomicity story end-to-end: Postgres commit, version update, and event/audit emission should use an outbox/CDC pattern so “commit happened but downstream didn’t” is recoverable deterministically.
- Re-evaluate dual tables: if you keep them, explicitly justify why two indexes on one table is worse than operating a reconciliation system forever.

### Should Consider
- Define an explicit “celebrity mode”: capped pages, pre-warmed first page, aggressive serve-stale, and strict cold-fill limits to protect Postgres.
- Tighten pagination correctness claims: keyset pagination is good, but concurrent inserts/deletes still change what a client sees; document the intended contract (snapshot-ish vs “best effort”).
- Blocking semantics: specify whether block auto-removes existing follow edges in both directions and how that interacts with cached lists and versions.

### Nice to Have
- Reduce Redis round trips (pipeline `GET ver` + `GET page`, or store a pointer key like `following:{u}:current -> v{n}`).
- Add a small set of “core invariant” dashboards/alerts (version regressions, version bumps without DB row changes, hot-key lock contention, divergence sampling rate).

## What's Working Well
- The versioned snapshot cache is a genuinely elegant way to buy “safe staleness” without distributed invalidation complexity.
- You’re explicit about long-tail users (celebrities) and stampede control; that’s where many social-graph designs fail.
- Trade-offs are honest and aligned with “small team operability”, and the design keeps the interesting part (caching model) front-and-center.