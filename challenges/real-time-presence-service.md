## Elegance Check

### The Core Insight
Treating the **server-side connection as truth** and using a **fixed-rate gateway liveness signal** (lease) to safely infer unclean disconnects is the clever bit—it cuts write amplification from `O(online_users)` to `O(session_churn + gateways)` without “online forever” bugs.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Presence Gateways | Only place that *knows* session reality; keeps the hot path close to the socket. |
| Presence Shards | Fast, consistent per-user aggregation (multi-device) and a single source for “online” answers. |
| Postgres (`last_seen`) | Durable, queryable historical boundary; doesn’t need to be hot. |
| Presence API | Centralizes privacy filtering + provides batch and watch primitives to product surfaces. |
| Kafka | Justified if you truly need **rebuild**, **audit**, and **downstream consumers** at this scale. |
| etcd | Justified if you need strong, well-understood coordination semantics for lease expiry and watches. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| etcd leases for gateway liveness | **Kubernetes Lease API** (if on k8s) or **Redis key TTL per gateway** | k8s ties you to the platform; Redis TTL is simpler but weaker semantics than etcd watches/consistency. |
| Kafka “presence log” for rebuild | **Compacted topic** (keyed by `session_id` or `user_id`) + periodic snapshots | More complexity in log design, but much faster shard warmup and less replay risk. |
| Separate LastSeen Writer service | **Shard-side buffered `last_seen` writes** (only on 1→0) | Fewer moving parts; you lose clean separation/audit pipeline unless you keep Kafka anyway. |
| Custom reverse index `gateway_id -> sessions` inside each shard | **Gateway-driven “death cleanup” message** via a control plane (best-effort) | Reduces etcd-watch fanout; but you still need lease-based truth for abrupt death. |
| Real-time watch directly off Presence API | **Subscription tier** earlier (even minimal) or SSE-only for some clients | More infra, but prevents watch becoming the hidden scaling cliff. |

## Stress Test

### Failure Scenarios

1. **etcd is down / unstable for 5 minutes**
   - Design’s answer: not addressed (only notes TTL sensitivity)
   - Recommendation: Strengthen — define behavior explicitly: “do not mass-offline on missed refresh if etcd is unavailable,” add hysteresis (e.g., require *N* missed renewals + local gateway health), and treat etcd errors differently from confirmed lease expiry.

2. **Network partition: gateways can’t reach shards, but clients stay connected**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — this is the nastiest split-brain for “connection = truth.” You need a policy: either (a) mark users “unknown” after a short grace, (b) degrade to “online but not emitting transitions,” or (c) force reconnect (close sockets) when shard connectivity is lost, so presence truth converges.

3. **Presence shard restarts while gateways are healthy**
   - Design’s answer: replay Kafka partition; serve “offline with stale last_seen” until warm
   - Recommendation: Strengthen — you must **fence** state transitions during warmup to avoid false 1→0 and premature `last_seen` writes. Common pattern: shard starts in `RECOVERING`, serves `unknown`, accepts updates idempotently into an internal buffer, and only emits online/offline once it reaches a known-good checkpoint.

4. **Kafka outage or prolonged lag**
   - Design’s answer: online remains correct; DB `last_seen` becomes stale
   - Recommendation: Acceptable if stated as an explicit SLO (“DB last_seen may lag by X”), but strengthen recovery: shards should either (a) buffer events locally with bounded memory + drop policy, or (b) write `last_seen` directly as a fallback when Kafka is unavailable (even if less ideal).

5. **Bad config / deploy causes lease TTL mismatch (e.g., refresh slower than TTL)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — add guardrails: config validation, runtime assertion (“refresh interval must be < TTL/3”), and staged rollout with automatic abort on “offline storm” metrics.

## Recommendations

### Must Fix
- Define semantics for **RECOVERING/UNKNOWN** and **fence emissions** during shard warmup to prevent incorrect `UserOffline` and `last_seen`.
- Specify end-to-end **idempotency**: dedupe `Connect/Disconnect` (at-least-once delivery) by `session_id`, and ensure reconnect can’t double-count sessions.
- Add a clear policy for **etcd unavailability vs confirmed lease expiry** to avoid mass false-offline cascades.

### Should Consider
- Use **compacted Kafka topics + snapshots** for faster, safer shard recovery than replaying an unbounded transition log.
- Add a **gateway↔shard resync protocol** (on shard restart or detected inconsistency) so correctness doesn’t depend entirely on Kafka replay being timely.
- Put hard limits and backpressure on `WatchPresence` (caps per client, per gateway, and per user fanout) with a graceful degradation mode.

### Nice to Have
- Explicit SLOs: “online freshness ≤ TTL,” “unknown rate,” “last_seen lag,” and “offline storm” alert thresholds.
- Chaos tests focused on: etcd flaps, shard restarts, gateway death storms, and partitions.

## What’s Working Well
- The design is honest about the real trap: **unclean disconnects** without per-user TTL writes.
- Multi-device semantics are handled cleanly via per-user session counting (with a crisp 1→0 boundary for `last_seen`).
- Operational knobs are clear (TTL/refresh), and you’ve separated hot-path serving (shards) from durability (Postgres) in a way that can scale.