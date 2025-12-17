## Elegance Check

### The Core Insight
Separating **durable trip truth (Postgres)** from **ephemeral “who’s nearby right now” (Redis)**, then making dispatch depend on a **bounded, city-local search surface** (cell rings + small fanout) is the right abstraction boundary for both latency and correctness.

### Components That Earn Their Place
| Component | Why It’s Necessary |
|-----------|-------------------|
| Postgres Trip Service | Single authoritative state machine with transactional guarantees and auditability (money + rider experience). |
| Redis Presence Index | Predictable low-latency reads/writes for high-rate location churn; designed to be lossy without corrupting trip truth. |
| Atomic reservation + leases | The simplest correctness anchor that prevents double-booking under concurrency without distributed locks across services. |
| Push/WebSocket delivery | Offers are inherently real-time and lossy; separating delivery lets dispatch stay deterministic and idempotent. |
| Streaming pricing | Decouples surge computation from request latency and supports smoothing/backpressure/audit. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Per-cell ZSET + TTL “liveness” | Store presence as `HSET driver:{id}` + periodic “active drivers per cell” materialization (or Redis Streams consumer) | Fewer hot keys and easier pruning, but adds a background job and makes “who’s nearby” slightly less direct. |
| Custom Event Bus (unspecified) | Use Kafka (or managed pub/sub) explicitly; or Redis Streams for city-local-only | Kafka adds ops but clarifies replay/ordering; Redis Streams simplifies stack but is weaker cross-region and for long retention. |
| Redis Lua reservation only | Move reservation to Postgres using `SELECT … FOR UPDATE SKIP LOCKED` on `drivers` table | Simplifies infra (one store), but likely misses tail-latency targets at metro scale and couples dispatch to DB health. |
| Separate Presence Ingest service | Fold into API Gateway edge (city-local) with strict rate limits | Fewer services, but gateway becomes stateful and harder to evolve independently. |
| H3 ring expansion always | Precompute “candidate cells per pickup” buckets (top-N neighbor cells by density/time-of-day) | Faster and cheaper at peak, but risks bias/odd edge cases and needs continuous tuning. |

## Stress Test

### Failure Scenarios

1. **Postgres down for 5 minutes**
   - Design’s answer: not addressed (focus is Redis outage + event lag)
   - Recommendation: **Strengthen** — define a hard behavior: reject new trip creation quickly; allow *read-only* status checks from cache; ensure driver accept flows fail fast (no “accepted” without durable transition). Consider a small “pending intent” buffer only if you can prove idempotent reconciliation.

2. **Network partition: Dispatch ↔ Redis (city-local)**
   - Design’s answer: partially addressed via leases/self-heal, but partition semantics aren’t explicit
   - Recommendation: **Strengthen** — define whether Dispatch treats Redis errors as “no candidates” vs “retry”; add circuit breaker + brownout mode (e.g., temporarily increase offer fanout only when Redis is healthy; otherwise fail fast with rider messaging).

3. **Slow-but-not-dead component: Push/WebSocket latency spikes**
   - Design’s answer: addressed (offer windows, fanout, lease expiry)
   - Recommendation: **Acceptable** — add one missing detail: require **driver acceptance to present an offer token + reservation/fencing token**, so late accepts can’t resurrect expired offers.

4. **Clock skew / stale location / out-of-order updates**
   - Design’s answer: addressed at a high level (“validate timestamps”, “last update wins”)
   - Recommendation: **Strengthen** — specify the rule precisely (server-receipt time vs device time), and how you prevent a skewed client from pinning itself “fresh” forever (e.g., cap future timestamps, require monotonic per-connection sequence numbers).

5. **10x traffic surge + reconnect storm**
   - Design’s answer: partially addressed (throttling, city isolation)
   - Recommendation: **Strengthen** — add explicit load-shedding priorities: drop high-frequency location updates first, then reduce candidate target (30→10), then widen rings only if CPU/Redis latency allows; otherwise fail fast to avoid tail-latency collapse.

## Recommendations

### Must Fix
- Define the **Postgres-unavailable** behavior for `request`, `accept`, `cancel`, and reconciliation so you never show “accepted” without a durable commit.
- Make the **offer/accept contract** explicit: accept must include `trip_id + offer_id + (fencing token or lease id)`; Trip Service must reject stale/expired offers deterministically.
- Address **presence data lifecycle** in Redis ZSETs: ZSET members don’t expire individually—define pruning strategy (score cutoff cleanup, key compaction, or a different structure) to avoid unbounded memory and “ghosts.”

### Should Consider
- Clarify **single-writer ownership** of driver assignment: is Redis reservation the source of truth for exclusivity, or does Postgres also enforce “driver on one trip” with a unique constraint? (Having both—with clear precedence—reduces edge-case ambiguity.)
- Add a **city brownout mode** playbook: feature flags for ring size, candidate count, fanout, offer window, and ETA dependency (maps on/off) to survive bad deploys and 3am incidents.
- Pricing: explicitly specify **max staleness**, **max step change**, and **hysteresis** (you hint at this) to prevent oscillations during event lag.

### Nice to Have
- A lightweight **simulation harness** (offline replay of events) to tune ring expansion/fanout and validate “offers per trip” under storms.
- A clearer story for **cross-city/cross-region** riders/drivers (airports, borders): who routes the request to the “right city” shard and how failover behaves.

## What’s Working Well
- The design is honest about what must be **correct** (trip state, assignment) vs what can be **best-effort** (presence), which is the key to an elegant dispatch system.
- Bounded search (H3 rings + candidate cap) and small fanout are exactly the techniques that keep peak load survivable without degrading driver UX.
- Leases + idempotent transitions acknowledge mobile reality (duplicates/out-of-order) and avoid “reliable delivery” fantasies.
- City as a failure domain is a strong operational choice: it makes paging, capacity planning, and incident scope sane for a small team.