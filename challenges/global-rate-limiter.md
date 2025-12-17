## Elegance Check

### The Core Insight
Turn “global rate limiting” into “occasional global quota allocation”: local decisions stay fast, and global correctness is concentrated into a single strongly-consistent lease issuer with an explicit overshoot bound.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Edge Gateway | Only place that can guarantee <2ms p99 by making the final allow/deny decision locally. |
| Global Quota Allocator | The one correctness-critical component that makes the “bounded overshoot” claim defensible. |
| Global Strong DB | Provides atomicity/durability for leases and policies; prevents “double spend” under retries/failures. |
| Regional RLS | Useful as a shock absorber (single-flight, policy evaluation, smoothing refill storms) so gateways stay simple. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Regional RLS + Regional Redis | Remove Redis: keep regional lease state in RLS memory + shard RLS (consistent hash) | Loses Redis durability; requires careful RLS failover (or accept faster drain/stricter throttling on RLS restarts). |
| Regional RLS + Regional Redis | Remove RLS: gateways refill directly from Redis (Lua/Redis-Cell style) and only call allocator when Redis low | Simpler service topology, but pushes more logic/coordination to gateways and increases Redis hot-key pressure. |
| Custom RLS implementation | Use Envoy’s global rate limit patterns (gateway filter + external RLS) as the “regional brain” | Less custom code, but you inherit Envoy integration constraints and may still need bespoke global leasing. |
| Allocator as separate service | Push allocator logic into the strong DB access layer (stored proc / transactional function) | Fewer moving parts; harder to evolve logic and observability; DB becomes more “application-aware”. |
| Global limits on highly-cardinal identities (e.g., IP) | Make only API keys global; keep IP limits regional + coarse global abuse controls | You lose strict global IP fairness, but you likely reduce 10M→massive cardinality pain and allocator/DB load. |

## Stress Test

### Failure Scenarios
1. **Allocator request retries + timeouts (duplicate lease grants)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen (this is the #1 way “bounded overshoot” silently becomes unbounded). Require idempotency keys per lease request stored transactionally in `Global Strong DB`, and define whether a “refill” is additive vs “set-to/max” to prevent accumulation.

2. **Bad policy rollout / emergency block**
   - Design’s answer: partial (shadow mode + operator kill switch mentioned)
   - Recommendation: Strengthen. Define policy versioning and how outstanding leases behave on policy change (honor until expiry vs revoke). For emergency blocks, don’t rely on allocator reachability—ship a fast path denylist/config to gateways (or regional RLS) that takes effect immediately.

3. **Clock skew / timekeeping bugs affecting lease expiry**
   - Design’s answer: not addressed
   - Recommendation: Strengthen. Make expiry based on monotonic “lease TTL remaining since receipt” rather than absolute wall-clock, or have gateways/RLS treat allocator-stamped `expires_at` conservatively (min with local). Otherwise skew can cause early expiration (over-throttling) or late expiration (overshoot).

4. **Regional Redis brownout (slow, not down)**
   - Design’s answer: addressed (fallback to in-memory emergency budget)
   - Recommendation: Strengthen. Ensure “emergency budget” is strictly carved out of already-leased tokens (not extra), or you break the overshoot bound exactly when you’re degraded. Also define backpressure: when Redis p99 rises, reduce refill concurrency and tighten local admission to keep the region stable.

5. **Hot key hits many regions at once (burst + anycast shifts)**
   - Design’s answer: addressed conceptually (`R * L` bound, adaptive leases, single-flight)
   - Recommendation: Acceptable with one clarification: explicitly guarantee “at most one active lease per (identity, region)” and prevent overlapping leases on retries. Also consider lowering `R` earlier via “super-region” leasing (your 100x idea is valuable at 10x too if you truly have 30–60 regions).

## Recommendations

### Must Fix
- Define the allocator’s exact state machine for token buckets (e.g., store `(tokens, last_refill)` or use a GCRA-style “theoretical arrival time”); “remaining for current refill period” reads like fixed-window semantics and will surprise reviewers/operators.
- Add end-to-end idempotency for lease grants (request IDs + transactional dedupe) and specify retry behavior; without this, overshoot bounds won’t hold under real failure.
- Specify policy change semantics (versioning, lease revocation rules, emergency block propagation) so operators aren’t stuck waiting for lease expiry during incidents.

### Should Consider
- Re-evaluate whether you need both `Regional RLS` and `Regional Redis`; pick one as the coordination point to reduce operational surface area.
- Treat global-IP limits as an explicit, justified choice (cardinality + churn); if you keep them, describe eviction/TTL strategy and how you avoid allocator hot partitions on NATed IPs.
- Make “fail closed vs fail open” a per-endpoint/per-tier knob (auth vs telemetry ingestion), not a single global behavior.

### Nice to Have
- Document the invariant behind the overshoot bound (one lease per region, no accumulation, conservative expiry) as a short “safety proof” section.
- Add a clear on-call runbook trigger: “allocator unreachable + leases draining” → what knobs to turn (tighten L, raise refill threshold, enable stricter local mode).

## What's Working Well
- The lease framing cleanly separates latency-sensitive data plane from correctness-sensitive control plane.
- The design is honest about trade-offs (bounded inaccuracy, under-utilization on failures) and picks sensible defaults (jitter, single-flight).
- You explicitly call out hot-key behavior and design for it, instead of assuming averages—this is where most global limiters die.
- Shadow mode + audit-grade telemetry requirements are pragmatic and make rollout safer.