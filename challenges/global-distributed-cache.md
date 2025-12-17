## Elegance Check

### The Core Insight
Routing correctness is the “strongly consistent” boundary; cached values are allowed to be regional/eventual. Pair that with built-in request coalescing (leases + soft/hard TTL) so misses can’t synchronize into a backing-store outage.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| **Lease authority on shard primary** | Single serialization point for refresh/miss without introducing a second lock system. |
| **Soft TTL + hard TTL** | Enables “serve-stale” to keep latency stable and protect the DB during refresh storms. |
| **Ownership epochs + reject stale routing** | Prevents the truly toxic failure mode: wrong-owner writes/leases during churn. |
| **Per-shard miss concurrency limits** | Turns “cache miss” into a controlled, bounded load on the backing store. |
| **Operational controls (drain/rebalance/freeze)** | Rebalancing and TTL policy changes are production events; explicit primitives reduce 3am footguns. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom **Raft shard map** | Use **etcd/Consul** (or managed equivalents) for membership/epochs; keep your ring logic but outsource consensus | Less bespoke control; dependency on another system, but much less correctness surface area to own |
| Custom **Gateway** for routing | Use **Envoy** consistent-hash LB + **xDS** updates, or a thin L4/L7 proxy that only does fanout/coalescing | Might constrain features (multi-key semantics, bespoke miss waiting), but eliminates a whole app-tier to maintain |
| Custom **cache engine** + replication | Start with **Redis/KeyDB/Dragonfly** as the data plane and add your lease/stale semantics at the edge (or via Lua/module) | Harder to perfectly fit your semantics; but dramatically reduces “build a database” risk for memory mgmt/eviction/replication |
| Optional “key updated” wakeups | Rely on bounded waits + polling/jitter initially | Slightly higher tail on waits, but removes cross-component signaling complexity until proven needed |
| Global invalidation “events” (underspecified) | Standardize on **Kafka/SNS/SQS/PubSub** with per-namespace topics and clear ordering guarantees | Costs/ops of a bus, but avoids reinventing delivery, replay, and consumer lag handling |

## Stress Test

### Failure Scenarios

1. **Backing DB is down for 5 minutes**
   - Design’s answer: serves stale until `hardTTL`, then bounded waits and “fail open” under concurrency limits
   - Recommendation: **Strengthen** — add explicit `stale-if-error` behavior (extend grace while origin errors), per-namespace “max stale” caps, and a hard circuit-breaker so “fail open” can’t become “everyone hits DB anyway”

2. **Network partition: Gateways can’t reach control plane**
   - Design’s answer: gateway watches shard map; “fails closed on ambiguous ownership”
   - Recommendation: **Strengthen** — define a degraded mode: continue routing on last-known-good map for reads, require epoch-checked writes at nodes, and ensure “fail closed” doesn’t turn into a region-wide miss storm during control-plane hiccups

3. **One replica is slow (not failing)**
   - Design’s answer: primary replicates before ack (predictable tail in-region)
   - Recommendation: **Strengthen** — specify backpressure: when replication lag rises, either (a) shed writes for affected namespaces, (b) temporarily ack async for low-value namespaces, or (c) auto-demote/replace the replica; otherwise you’ll see tail-lat spikes and gateway retries amplify load

4. **Bad config deploy: TTLs lowered / grace reduced**
   - Design’s answer: notes TTL changes are traffic events; “roll gradually per namespace”
   - Recommendation: **Strengthen** — enforce guardrails in the control plane: max % TTL reduction per hour, mandatory jitter on expirations, and canary + automatic rollback on `lease_grant_rate` / `hard_miss_rate` regressions

5. **Regional failover: cold cache + 10M QPS burst**
   - Design’s answer: clamp miss concurrency per shard, rely on stale-while-revalidate once warmed
   - Recommendation: **Acceptable if tightened** — you need an explicit “warmup posture”: aggressive negative caching for absent keys, admission control on large objects, and (crucially) a plan for hot keys (top 0.1%) so single primaries don’t become the new bottleneck during rewarming

## Recommendations

### Must Fix
- Specify the exact semantics for **lease holder failure** (client dies mid-lease): how/when leases expire, whether waiters are notified, and how you prevent “lease churn” from becoming its own storm.
- Make “bounded waiting” **resource-bounded** end-to-end (gateway and node): cap waiters per key and per shard, and ensure waiting doesn’t consume unbounded threads/heap (async/evented waiting).
- Clarify **global invalidation**: delivery guarantees, ordering, replay, and what happens when consumers lag or a region is partitioned (this is the hidden “global correctness” path).

### Should Consider
- Add **TTL jitter / probabilistic early refresh** by default to reduce synchronized softTTL crossings (complements leases; lowers contention).
- Treat hot keys explicitly: optional **read-from-replica** for hot keys (primary still mints leases), or “hot shard” isolation sooner than “10x scale,” because your workload skew is already extreme.
- Reduce bespoke surface area: outsource consensus (etcd/Consul) and/or reuse a proven cache data plane unless “Redis-like” requires deep custom semantics.

### Nice to Have
- A “safe ops” workflow: staged **rebalance plans**, dry-run diffs (“keys moved”, “memory risk”), and a one-command rollback of ring changes.
- Multi-tenant controls if this is “managed”: authn/z, per-namespace quotas, noisy-neighbor isolation, and audit logs for admin commands.

## What's Working Well
- The design is honest about the real problem: **miss-path synchronization**, not raw GET/SET throughput.
- Strong separation of concerns (routing correctness vs value eventuality) is a clean, scalable mental model.
- Epoch-based rejection + “miss over wrong write” is the right bias for caches under churn.
- Operational notes are pragmatic (TTL changes, rebalancing throttles, metrics that actually predict incidents).