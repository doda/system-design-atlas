## Elegance Check

### The Core Insight
Treating cardinality as an explicit, enforceable budget (not an emergent scaling property), combined with “mutable hot window + immutable blocks in object storage,” is the right conceptual split for stability and long retention.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Ingest Gateway | The only place you can cheaply reject/shape writes before they allocate TSDB head memory and trigger cluster-wide blast radius. |
| Ingester Ring | Owns the hot window, WAL durability, and low-latency recent reads; isolates object storage from write path. |
| Object Storage | Cost-effective, durable source of truth for long retention; immutable blocks enable caching and compaction. |
| Store Gateway | Turns object storage into a scalable read backend via index/chunk caching and restart-friendly behavior. |
| Query Frontend | The safety valve for PromQL (budgeting, splitting, caching, fairness) so “one bad query” doesn’t become an incident. |
| Compactor | Prevents long-term cost/query fanout from spiraling; centralizes retention/downsampling semantics. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| “Build this pipeline” as a bespoke system | Adopt an existing battle-tested stack: Grafana Mimir/Cortex (ingest+querier+compactor) + Thanos patterns (index-header, store gateway) | Less design freedom; you inherit project constraints, but you also inherit years of operational edge-case handling. |
| Custom ring + membership implied | Use memberlist (gossip) or Consul/etcd for ring state (like Cortex/Mimir) | Adds a dependency, but makes failure behavior explicit and reduces “mysterious sharding” bugs. |
| Hard per-tenant cardinality enforced “in ingesters” | Use shuffle sharding (per-tenant ingester subset) + per-ingester limits, with optional central limit service | True global “hard cap” is tricky without coordination; shuffle sharding gives strong isolation with simpler mechanics. |
| Custom query cost estimation (“max series scanned”) | Reuse proven query-frontend/querier implementations (Mimir/Cortex) or keep initial guardrails coarse (range/step/concurrency) | Fine-grained estimators are complex and can be wrong; coarse controls are safer early but less user-friendly. |
| “New series admission structure” local only | Redis-backed token bucket for “new series/sec” (per tenant), or accept per-ingester buckets with shuffle sharding | Redis adds ops; per-ingester buckets are simpler but can be bypassed by fanout unless sharding is tenant-sticky. |
| “Boring glue” underspecified | Explicit control-plane: tenant configs, limit versions, rollout, audit | More formalism up front, but it’s what prevents 3am “who changed limits?” events. |

## Stress Test

### Failure Scenarios
1. **Ring KV store (etcd/Consul) down for 5 minutes**
   - Design’s answer: not addressed (ring exists conceptually, but membership/state store isn’t specified)
   - Recommendation: Strengthen (define whether you use memberlist gossip, a KV store, or both; define read/write behavior during outages and how tokens/ownership changes are gated).

2. **Network partition: ingesters split-brain (two sides accept writes)**
   - Design’s answer: not addressed (replication mentioned, but quorum/ownership fencing isn’t)
   - Recommendation: Strengthen (define write quorum rules, how a tenant/series maps to replica set, and how you prevent “dual leaders” from diverging; consider “ingest only if ring is stable” or fencing via KV epochs).

3. **Object storage slow/erroring for hours (not minutes)**
   - Design’s answer: partially addressed (serve recent from ingesters; cache; shed long-range)
   - Recommendation: Strengthen (explicitly define: cache warmup strategy, how LIST storms are avoided, whether you rely on periodic metadata sync, and how compactor behaves—pause vs build backlog—and when you page).

4. **Bad limits/config rollout rejects healthy tenants globally**
   - Design’s answer: not addressed (limits “visible/versioned” is noted, but no rollout mechanics)
   - Recommendation: Strengthen (add staged rollout + per-tenant overrides + fast revert; require “dry run” mode in gateway that reports would-reject without enforcing).

5. **Traffic 10x + cardinality 10x during an incident (agents retry + deploy bug)**
   - Design’s answer: partially addressed (reject early; token bucket for new series; query budgets)
   - Recommendation: Acceptable if you add explicit backpressure contracts: remote_write retry guidance, per-tenant ingest concurrency caps, and a global “protect the cluster” mode that tightens limits automatically.

## Recommendations

### Must Fix
- Make “hard per-tenant caps” mechanically true: either define coordination for global cardinality or adopt shuffle sharding + per-ingester caps (and be honest that it’s “hard within the shard,” not globally absolute).
- Specify ring/membership and fencing: what stores ring state, how ingesters join/leave, what happens during partitions, and what guarantees writes rely on.
- Define multi-tenant safety boundaries end-to-end: authn/z, tenant-aware caches (no cross-tenant leakage), and per-tenant query fairness (not just max limits).
- Clarify partial results policy: when queries may be partial, how it’s surfaced, and how dashboards/alerts should behave.

### Should Consider
- Prefer an existing implementation (Mimir/Cortex/Thanos patterns) unless there’s a clear differentiator; your design already matches those primitives, so “compose” may beat “build.”
- Add an explicit control plane for limits (schema, versioning, rollout, audit, emergency overrides) since limits are now a core product contract.
- Make object-store read amplification a first-class design point: index-header caching, minimizing LIST calls, and a clear cache hierarchy (RAM vs SSD) for store gateways.

### Nice to Have
- Tenant isolation upgrades: shuffle sharding everywhere (ingest + query), “noisy neighbor” containment by default.
- Operator ergonomics: top-N offending label keys/metrics surfaced automatically with runbooks and suggested relabel configs.
- Clear SLO-driven load shedding: deterministic rules for tightening query windows/steps and disabling expensive features per tenant during incidents.

## What's Working Well
- The separation of mutable hot path (WAL + ingesters) from immutable long-term blocks is operationally calm and scales naturally.
- You correctly treat cardinality as a budgeted resource with explicit rejection, which is the difference between “degraded” and “outage” at this scale.
- Query frontend as a safety layer (splitting, caching, bounded execution) is the right place to make PromQL safe without neutering it.
- Failure modes are discussed in the right order (cardinality → memory/index → query fanout), and the operational notes focus on the real pager metrics (WAL replay, compaction lag, query budgets).