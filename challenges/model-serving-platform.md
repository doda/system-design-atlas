## Elegance Check

### The Core Insight
Decoupling **serving identity** (model+version) from **GPU residency** (what’s loaded) and making “model activation” a first-class, rate-limited workflow (prefetch → load/warm → cutover) is the non-obvious move that prevents load storms and keeps tail latency sane.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Edge Gateway (Envoy) | One consistent place for auth + deterministic sampling + rollout headers across all models/tenants. |
| Model Router | Turns tiers/quotas/backpressure into enforceable behavior at request time (not just “desired state”). |
| GPU Workers (Triton) | Proven batching/runtime semantics; avoids per-framework snowflakes. |
| Object Store | Immutable artifacts + dedupe + integrity; clean separation of build vs serve. |
| Metadata DB (Postgres) | Correct rollout state, auditability, and quota truth; “boring” and operable. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “router cache with TTL” + bespoke invalidation | Postgres `LISTEN/NOTIFY` for rollout/routing changes; router keeps local in-memory snapshot | Requires careful reconnect/replay; still need cold-start fallback behavior. |
| Separate “model-cache daemon” service + bespoke API | DaemonSet that exposes cache status via node labels/annotations + gRPC health, or reuse K8s Device Plugin/NVIDIA operator patterns | Less custom protocol, but labels are eventually consistent; need guardrails for stale metadata. |
| Custom activation orchestration in router/controller | Temporal (or Argo Workflows) for activation steps and retries; router just awaits readiness | Adds dependency, but removes a lot of tricky retry/idempotency logic from hot path. |
| Shadow sink + log store as a custom pipeline | Kafka/SQS + compacted topics + consumer diff workers | Adds messaging infra, but simplifies backpressure, replay, and “log store is slow” failure modes. |
| “Global scheduler at 100x” as future work | Start earlier with K8s scheduler plugin / Kueue / Volcano for GPU placement constraints | Less bespoke, but may not model interference perfectly; still valuable before building a new scheduler. |

## Stress Test

### Failure Scenarios
1. **Postgres down for 5 minutes**
   - Design's answer: cached routing tables with TTL; deploy pipeline halts
   - Recommendation: Strengthen (define *which* ops must continue: quota enforcement, rollback decisions, artifact quarantine; consider “last-known-good” snapshot with explicit staleness budget and alerting)

2. **Object store throttling / partial outage**
   - Design's answer: node-local cache + admission control
   - Recommendation: Strengthen (cache corruption/eviction policy, checksum verification on NVMe, exponential backoff + global prefetch rate limits; define behavior when cache misses persist: fail cold tier fast vs queue)

3. **Network partition: router ↔ subset of GPU workers**
   - Design's answer: not addressed
   - Recommendation: Must fix (router should treat workers as ephemeral: circuit-break, fast health-based eviction, avoid “blackhole” routing; define in-flight request retry policy to avoid duplicate inference)

4. **One component is slow (shadow sink/diff pipeline lagging)**
   - Design's answer: async diffs keep prod latency clean
   - Recommendation: Strengthen (explicit backpressure + sampling downgrade rules; “diff lag” should gate promotions and be visible as a rollout SLO)

5. **Bad config/rollout policy pushes wrong headers or tier mapping**
   - Design's answer: not addressed
   - Recommendation: Must fix (config versioning + canary the control-plane configs; safe defaults in gateway/router when headers are malformed; “break glass” global rollback switch)

## Recommendations

### Must Fix
- Define **partition/blackhole semantics** between router and workers (health, retries, idempotency, and fast fail vs queue per tier).
- Make **staleness explicit** for routing/quotas when Postgres is unavailable (what is allowed to drift, for how long, and how you alert).
- Add a clear **backpressure contract** for shadow/diff/logging (what drops first, and how that affects rollout gates).

### Should Consider
- Collapse custom orchestration into a **workflow engine** (Temporal/Argo) so activation retries, dedupe, and timeouts aren’t reinvented in the request path.
- Use **Kafka/SQS** (or Redis Streams at smaller scale) for shadow/diff to get replay, consumer scaling, and simpler failure handling.
- Make multi-tenancy isolation more concrete: **per-tenant concurrency limits + fair queuing** at router; define “noisy neighbor” handling within the same tier.

### Nice to Have
- Formalize a **“model load SLO”** (p95 activation time, queue depth budgets) alongside inference SLOs.
- Add **prewarm forecasting** as a first-class feature earlier (access-log driven) to reduce cold-tier pain without scaling complexity.
- Document “3am ops” runbooks: quarantine digest, drain a node pool, disable shadowing, clamp activations.

## What's Working Well
- The activation workflow (prefetch → warm → cutover) plus admission control is a strong, elegant answer to load storms.
- Using Triton + KServe keeps the data plane “boring” and focuses custom effort where it matters (routing/tiering/rollout safety).
- Deterministic edge sampling + async diffing is the right latency/privacy posture, and the retry-storm dedupe callout shows good production instincts.