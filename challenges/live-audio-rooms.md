## Elegance Check

### The Core Insight
Separate a **strict, single-writer control plane** from a **line-rate media plane**, and make moderation **authoritative at the SFU** so the listener experience remains correct even with buggy/malicious clients.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| SFU cluster | Bandwidth-efficient fan-out for few speakers; the only place you can *guarantee* “mute/kick” affects what listeners receive. |
| Room Service (single-writer per room) | Avoids distributed locks while giving a totally ordered stream of authority changes. |
| TURN/STUN | Connectivity; without it, “reliability” becomes an illusion for a meaningful % of mobile users. |
| Postgres | Durable metadata + trust/safety auditability + idempotency anchoring. |
| Metrics/logs | Required to debug real-time issues and to prove moderation actions took effect (or didn’t). |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Kafka/Pulsar for room events + Postgres for metadata | Start with **Postgres outbox + CDC** (or LISTEN/NOTIFY for low scale) | Less decoupling/throughput than Kafka; but simpler ownership and fewer moving parts early. |
| “Room epoch increments on mute/kick” embedded in all publish leases | Use **per-publisher generation** (or per-lease ID allowlist) while keeping a room epoch only for “speaker set” changes | Slightly more state in SFU/control channel, but avoids collateral disruption to other speakers on every moderation action. |
| Custom shard leader election | Use **Postgres advisory locks** (single region) or **etcd/Consul** for leader election | Adds a dependency (etcd) or ties you to Postgres availability; but reduces bespoke coordination code. |
| Cascading SFUs as a distinct special mode | Make **two-tier topology the default** once you have “celebrity room” requirements | More operational complexity, but fewer “mode switches” and less surprise scaling behavior. |

## Stress Test

### Failure Scenarios

1. **Postgres is down for 5 minutes**
   - Design’s answer: partly addressed (Room Service can continue briefly; leases expire)
   - Recommendation: Strengthen  
     - Define the *system of record* for authority: if Postgres is required for idempotency/audit, Room Service needs a degraded mode (read-only moderation? freeze state?) and a clear “room is live but locked” UX.  
     - If Kafka is the durable log, make that explicit and use Postgres asynchronously via outbox/consumers.

2. **Room Service ↔ SFU control channel is partitioned (media still flows)**
   - Design’s answer: not fully addressed (immediate enforcement depends on push)
   - Recommendation: Must fix  
     - SFU should have a fast fallback to verify/refresh authority (e.g., cached policy with short TTL + pull on miss, or replicated authority store with watches).  
     - Define “fail closed” semantics: after N seconds without authority refresh, do you drop all publishing, or only new publishes?

3. **Moderator mutes one speaker in a busy room**
   - Design’s answer: epoch-based enforcement
   - Recommendation: Must fix (as written)  
     - If you bump a **room-wide epoch** and require leases to match it, you risk **muting everyone** (all other speakers’ leases become stale).  
     - Prefer per-speaker revocation (generation/lease-id allowlist) so one action only affects one publisher.

4. **Bad config deploy to SFU (e.g., codec params, ICE policy, auth check bug)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen  
     - Add canary SFU pools + room placement rules (small % of rooms) + rapid rollback.  
     - Keep a “safe mode” config (no recording taps, minimal stats, conservative bandwidth) for incident response.

5. **Traffic 10x spike + one 100k listener room**
   - Design’s answer: cascading + admission control
   - Recommendation: Acceptable, but clarify  
     - Define automated triggers: when to split to edges, how to choose edge regions, how to cap/queue joins, and how you prevent a single room from starving others (egress budgets per pool).

## Recommendations

### Must Fix
- Fix the **epoch/lease invalidation blast radius**: use per-speaker revocation (generation or lease-id allowlist), not room-wide epoch bumps for mute/kick.
- Define behavior for **SFU-control partition**: explicit fail-open/closed policy and an authority refresh/fallback path.
- Make event durability consistent: if using both Postgres and Kafka, specify **transactional outbox** (or pick one as the authoritative log) to avoid lost/duplicated moderation/audit events.

### Should Consider
- Start simpler on the event bus: Postgres outbox/CDC can cover analytics + replay for a long time with fewer ops burdens.
- Bind publish leases to the WebRTC session (e.g., include DTLS fingerprint / session id) to reduce token theft/replay risk.
- Spell out cross-region strategy: are rooms single-region for control + media, and what’s the user-visible behavior on region failover?

### Nice to Have
- A “celebrity room runbook” automation: one-click **freeze speaker set**, force cascade, disable non-essentials, and apply stricter join throttles.
- Explicit backpressure UX: “room full / retry” semantics and listener join queuing with jitter to avoid thundering herds.

## What’s Working Well
- Clear separation of concerns: control plane decides truth; media plane enforces truth—this is the right abstraction boundary.
- The SFU-as-authority-enforcer framing is honest about what “hard mute” actually requires.
- Speaker caps + TURN cost awareness + room-level SLOs show good production instincts.
- Cascading SFUs + a future CDN path acknowledges the real scaling cliff without overbuilding on day one.