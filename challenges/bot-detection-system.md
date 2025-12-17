## Elegance Check

### The Core Insight
Treating bot detection as **risk orchestration with a friction ladder** (not binary classification), and anchoring reputation to **hard-to-rotate entities (device/account)** while using IP/ASN as fast-decaying hints, is the clean “make it robust under NAT + adversaries” move.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Edge (CDN/WAF) | Lowest-latency enforcement point; shrinks bypass surface; can run cheap invariants + coarse rate limits. |
| Risk Engine (thin) | Centralizes decision logic + explainability; keeps edge logic small and policy-driven. |
| Redis (hot TTL state) | Makes rate limits/counters cheap at high RPS; enables fast decay and “recent outcome” checks. |
| Postgres (versioned policy) | Auditable, rollbackable control plane for thresholds/rollouts; immutable policy history. |
| Event stream + analytics | Separates online safety from offline learning; enables replay/incident forensics without blocking requests. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “Event Stream” abstract component | Use a managed log (Kafka/Kinesis/PubSub) or even “good enough” buffered sinks per region | Less flexibility if you later need exactly-once semantics; but fewer bespoke failure modes. |
| Risk Engine always in the request path | Push *only* low-risk decisions to edge rules + CDN rate limiting; call Risk Engine only for sensitive routes | Slightly more policy complexity (routing), but big reduction in dependency surface under attack. |
| Postgres policy fetch at runtime | Distribute policies via CDN KV/config service + aggressive caching (ETag/version pinning) | Harder immediate propagation; but avoids Postgres as a tail-latency contributor. |
| Redis as the universal hot store | Use CDN-native rate limiting/bot signals for IP/ASN buckets; reserve Redis for device/account outcomes | Fewer unified knobs; but less cardinality pressure and fewer hot keys in Redis. |
| Custom scoring blob storage in Postgres | Keep “small models” as a constrained rules DSL (or OPA/Rego) with strict limits | Less ML expressiveness; more predictable and reviewable changes. |

## Stress Test

### Failure Scenarios

1. **Redis is down or slow for 5 minutes**
   - Design’s answer: fallback to policy-only decisions; degrade IP/behavioral limits first
   - Recommendation: Strengthen — define *explicit degraded-mode policies per route* (e.g., login always CHALLENGE, checkout never BLOCK), and ensure Redis timeouts are hard-capped to protect p99.

2. **Postgres (policy) is unavailable or a bad policy deploy happens**
   - Design’s answer: rollout discipline + kill-switch; policy versioning
   - Recommendation: Strengthen — ensure the edge/Risk Engine can operate for hours on the *last known good policy* (local cache + signed bundles), and require “two-key turn” for policies that can increase BLOCK rate on critical routes.

3. **Network partition between Edge ↔ Risk Engine (regional)**
   - Design’s answer: not explicitly addressed beyond “safe degradation”
   - Recommendation: Must fix — define a deterministic edge-side default per endpoint when Risk Engine is unreachable (and log as `FALLBACK_DECISION`), plus circuit breakers to avoid self-inflicted thundering herds.

4. **Event stream/ClickHouse is degraded (backpressure) during an attack**
   - Design’s answer: offline never blocks online
   - Recommendation: Strengthen — make loss-tolerant ingestion explicit (drop/shed low-risk samples first, keep challenged/blocked full-fidelity), and document retention guarantees for “replay to rebuild reputation” (replay is only as good as what you actually retained).

5. **Signed telemetry/device token is replayed, stolen, or key rotation goes wrong**
   - Design’s answer: signed telemetry, device token hardening mentioned
   - Recommendation: Must fix — specify anti-replay (nonce + short expiry + binding to TLS/session hints), key rotation procedures (overlap windows, per-tenant keys), and what happens if JS telemetry is absent/spoofed (especially for “ALLOW_WITH_TELEMETRY” paths).

## Recommendations

### Must Fix
- Define **edge-side deterministic fallback** behavior when Risk Engine/Postgres/Redis are unreachable (by route class), with strict timeouts and circuit breakers.
- Specify **telemetry/device token security model** (replay resistance, expiry, binding, rotation, compromise response).
- Add **multi-region/partition strategy** for Redis hot state (or explicitly accept regional isolation) to avoid global blast radius and clarify consistency expectations for reputation.

### Should Consider
- Treat CDN/WAF native features as “boring primitives”: move **IP/ASN burst controls and basic rate limiting** there; keep Redis mostly for higher-stability outcome-driven signals.
- Make “replay to rebuild reputation” honest: document which state is rebuildable (from stream) vs. ephemeral (lost with Redis) and design runbooks accordingly.
- Add a **shadow mode** for new policies/models (compute reasons + action, but don’t enforce) with automatic diff reports before canary enforcement.

### Nice to Have
- A compact, reviewable **policy DSL** with static checks (max action change, bounded reason vocab, per-route safety rails).
- A “3am-proof” operator UX: per-route **blast radius previews** (“this change increases CHALLENGE on login from 2%→8% for iOS Safari”).

## What’s Working Well
- Clear separation of **online decision plane** from **offline tuning**, with explicit avoidance of “analytics store in the hot path”.
- Monotonic, explainable aggregation (“bad overrides, good attenuates”) and a bounded reason taxonomy—this is exactly what makes on-call workable.
- Strong operational posture: versioned policies, canaries/holdbacks, and explicitly planned degradation behavior (needs a bit more concreteness to be production-ready).