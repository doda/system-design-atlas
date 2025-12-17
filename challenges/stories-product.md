```markdown
## Elegance Check

### The Core Insight
Separating **privacy-gated serving** (mint short-lived URLs at origin) from an **append-only view plane** (conditional uniqueness + async materialization) is the right simplification: it keeps playback fast while making “viewer lists must be correct” tractable.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Story API | Centralizes privacy decisions per play and mints short-lived media URLs; keeps CDN out of the auth business. |
| CDN + Object Store | Offloads bytes and supports lifecycle deletion aligned to story TTL/grace. |
| Story DB (partitioned by expiry) | Makes expiration operationally cheap (drop partitions) and keeps story metadata authoritative. |
| Viewer Store (uniqueness + TTL) | Provides the “one viewer once per story” source of truth with automatic expiry. |
| Stream/Worker (materialization) | Turns “first-seen” into ordered pages + counts without adding latency to playback. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Relationship Service + Graph DB for follow/block/close-friends | **Postgres** adjacency tables (+ indexes) + **Redis** cache; or a managed graph only if you truly need multi-hop queries | You lose “graph DB” flexibility, but this domain is mostly 1-hop membership checks; operational footprint drops. |
| Custom “stream worker” pipeline unspecified | Use a managed primitive: **DynamoDB Streams**, **Kafka** (incl. compacted topics), **Kinesis**, or **SQS + outbox** | Less bespoke control, but you gain standardized failure handling, replay, and tooling. |
| Separate Seen/Timeline/Counts stores implied | Consider a **single-table design** (e.g., DynamoDB) with (a) conditional put for seen, (b) GSI for timeline ordering, (c) atomic counters | Tighter coupling to one datastore’s patterns, but fewer moving pieces and clearer correctness. |
| Per-viewer “seen state” maintained by worker | If stories per creator are small, store **per-(viewer, creator) last_seen_at** and compute seen story IDs by timestamp | Doesn’t support arbitrary per-story seen if you need it, but can drastically reduce write amplification. |
| “Invalidate on block/unblock” plus short TTL caches | Push to **event-driven invalidation** (relationship change stream) and keep the serving path doing a cheap “block override” check | Slightly more plumbing, but reduces “brief window of wrong access” risk. |

## Stress Test

### Failure Scenarios
1. **Viewer Store (Seen table) is down for 5 minutes**
   - Design's answer: not addressed (worker lag is covered, but not the tier-0 uniqueness write failing)
   - Recommendation: **Strengthen** — define client/server behavior: queue locally? return success without counting? degrade to “views may be missing”? Also add circuit breaker + retry budgets so playback isn’t hostage to view logging.

2. **Network partition / high latency between Story API and Relationship Service**
   - Design's answer: partially addressed (cache TTL + invalidation), but unclear on “what if relationship source is unreachable”
   - Recommendation: **Strengthen** — decide a hard policy: fail-closed for privacy (safer) vs fail-open (better UX). Most teams pick: tray can be stale-ish, but **play must fail-closed** for private stories and blocks.

3. **Hot partition: a viral story gets massive concurrent unique viewers**
   - Design's answer: implied constant-time conditional write, but no hotspot mitigation
   - Recommendation: **Strengthen** — conditional uniqueness on `(story_id, viewer_id)` is fine, but you still need a datastore that stays stable under massive writes for a single `story_id`. Call out the intended tech (e.g., DynamoDB partitioning behavior, Redis+durable fallback, or sharding by `(story_id hash prefix, viewer_id)`).

4. **Bad config: grace/TTL mismatch across CDN, object lifecycle, and DB**
   - Design's answer: mentions “single config knob,” good intent but no enforcement mechanism
   - Recommendation: **Strengthen** — make `grace` a versioned config pushed to all systems with validation; add an invariant check (e.g., “object lifecycle >= DB TTL >= signed URL max TTL”) and alarms when violated.

5. **Signed URL leakage/sharing within the expiry window**
   - Design's answer: relies on short-lived URLs; revocation is “eventual” via expiry
   - Recommendation: **Acceptable (if explicit)** — document the security posture: you prevent long-lived replay, not instant revocation. If instant revocation is required, you’ll need token introspection at the edge/origin or per-request auth (higher cost).

## Recommendations

### Must Fix
- Specify the **exact data-store semantics** for conditional insert + TTL (and why it will hold at 35k/s peak with spikes), including hotspot behavior for viral stories.
- Make event emission from “new seen record” **atomically derived** (e.g., Streams or outbox), so you don’t lose timeline/count updates when ingest succeeds but publish fails.
- Define **degrade policies** for relationship-source failures and for view-ingest failures (so on-call knows the intended behavior).

### Should Consider
- Replace Graph DB with **Postgres + Redis** unless you truly need multi-hop graph queries; it’s a big ops tax for mostly membership checks.
- Simplify “seen state” to **(viewer, creator) last_seen_at** if the product semantics allow it; it removes a lot of per-view writes.
- Treat creator viewer lists as sensitive: add **access controls, audit logs, encryption**, and explicit retention guarantees (TTL isn’t always a compliance story).

### Nice to Have
- Explicit SLOs and budgets: p95/p99 for play auth, URL mint, seen write; plus a runbook for “worker lag,” “graph down,” “viewer store throttling.”
- Abuse controls: rate limits per viewer/device, bot thresholds, and replay detection for view ingest.

## What's Working Well
- The two-plane split is clean and keeps the “interesting” correctness (uniqueness) away from the “must be fast” path (playback).
- TTL/partition-based expiration is operationally elegant and avoids fragile delete jobs.
- The design is honest about eventual consistency for creator analytics and proposes the right UX mitigation (“updating…”).
```