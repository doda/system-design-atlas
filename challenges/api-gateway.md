## Elegance Check

### The Core Insight
Split the gateway into a **boring, fast Envoy data plane** plus a **small, auditable control plane**, and treat “global quota correctness” as **best-effort fairness** via short leases rather than per-request central coordination.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Envoy edge gateway | Proven routing/retries/circuit breaking + gRPC-JSON transcoding with low latency and battle-tested failure behavior. |
| xDS control plane | Centralizes policy with validation, rollout control, and auditability; keeps data plane dumb and consistent. |
| Protobuf as source of truth | Prevents “JSON drift”; gives a strict evolution model and deterministic transcoding/contracts. |
| Global quota state (Redis or equivalent) | Enables cross-instance fairness so one POP/instance can’t let a tenant exceed fleet intent during spikes. |
| Observability pipeline | Required to make limiting/resiliency explainable per tenant and to safely roll out policy changes. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate **Rate Limit Service** hop for decisions | Let Envoy do **local** limiting only, and use control plane to allocate **per-POP budgets** (static or periodically recomputed) | Less “real-time” fairness; better operational simplicity and fewer moving parts at the edge. |
| Rate Limit Service + Redis leases | Remove the service: gateways (or a tiny sidecar) **mint/renew leases directly from Redis via a Lua script** keyed by `(tenant, pop)` | Harder to centrally debug; pushes more logic to edge, but deletes an entire service tier. |
| Redis HA cluster per region | Use a purpose-built global limiter (e.g., Envoy RLS compatible “ratelimit” + Redis, or Redis Cell/GCRA implementations) | Still Redis, but you adopt a known limiter semantics/implementation instead of custom logic. |
| “Expensive vs cheap” per-route failure behavior | Default-safe posture: **fail-closed unless explicitly marked fail-open**, with a strict allowlist for fail-open routes | Slightly more friction for adding endpoints; fewer 3am surprises and safer defaults. |
| xDS carries everything | Keep xDS for routing/timeouts; deliver large protobuf descriptor sets via **artifact/CDN** with version pinning in xDS | More deployment plumbing; avoids bloating xDS pushes and reduces risk of partial descriptor/config mismatch. |

## Stress Test

### Failure Scenarios

1. **Redis is down for 5 minutes**
   - Design’s answer: Continue on cached leases; route-specific degradation (fail-closed expensive, fail-open cheap with caps).
   - Recommendation: **Strengthen** — specify hard bounds: max time you’ll run on stale leases, max local burst under fail-open, and how you prevent “lease renewal thundering herd” when Redis recovers.

2. **Rate Limit Service is slow (not down)**
   - Design’s answer: Not explicitly addressed (focuses on unreachable).
   - Recommendation: **Must address** — define timeouts and fallback: do you use last-known decision, cached lease-only mode, or local-only buckets? Also ensure slow RLS can’t become the new bottleneck during reconnect storms.

3. **Network partition: POP isolated from Redis/control plane**
   - Design’s answer: Degrade on Redis loss; control plane not discussed.
   - Recommendation: **Strengthen** — document “config freeze” behavior: how long gateways run safely on last config, what happens to revoked tenants/keys, and whether you allow continued traffic on stale auth/routing policy.

4. **Bad config rollout (quotas/routes)**
   - Design’s answer: Canary + validation + rollback on SLO breach.
   - Recommendation: **Strengthen** — add “semantic” checks: quota changes should be diffed against tenant baselines, require explicit acknowledgement for large deltas, and include a dry-run/impact estimate from recent traffic.

5. **Reconnect storm: traffic 10x while backends brown out**
   - Design’s answer: Tight timeouts, bounded retries, circuit breaking, shedding.
   - Recommendation: **Acceptable but clarify** — explicitly cap retries per request and per upstream, ensure hedging is off by default, and define which signals trigger shedding first (queue length, concurrency, upstream latency, error budgets).

## Recommendations

### Must Fix
- Define behavior when **Rate Limit Service is degraded** (timeouts, fallback mode, and ensuring it can’t cascade-fail the gateways).
- Make “fail-open vs fail-closed” **safe by default** (explicit allowlist for fail-open) and specify hard caps/bursts in degraded modes.
- Specify control-plane outage semantics: **how long stale config is trusted**, and how you handle **revocations** (keys/tenants/routes) during partitions.

### Should Consider
- Delete a whole tier by moving lease minting to **Redis Lua** (or adopt an existing Envoy-compatible limiter implementation) to avoid custom RLS operations burden.
- Consider **per-POP or per-region quota allocation** from the control plane as the “global fairness” mechanism (simpler, fewer runtime dependencies).
- Treat protobuf descriptors as versioned artifacts to avoid **xDS bloat** and reduce “route points to method not in descriptor” failure modes.

### Nice to Have
- Explicit “anti-stampede” design: jittered renewals, per-tenant backoff, and recovery mode after Redis returns.
- A documented, stable **HTTP error model** (status codes + body schema + retryability headers) tied to protobuf/gRPC errors.
- Runbooks: “Redis down”, “RLS slow”, “config rollback”, “backend brownout” with exact toggles and dashboards.

## What’s Working Well
- The data-plane/control-plane split is clean and matches the latency and operability goals.
- The lease approach is a good, pragmatic answer to “global limits without per-request coordination.”
- Deterministic limit reasons (`tenant_cap`, `device_cap`, `endpoint_cap`) is exactly what support and SRE need.
- Calling out the two classic traps (centralized decisions and schema-less transcoding) shows good production instincts.