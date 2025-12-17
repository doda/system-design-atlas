## Elegance Check

### The Core Insight
Separating **secret storage (encrypted blobs)** from **secret validity (versions + leases)** makes reads boring and pushes complexity into an observable, bounded **rotation control plane**—that’s the right “Vault-like” spine.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| `Postgres (Ciphertext+Metadata)` | Strong transactional source-of-truth for versions, lease/rotation state, and audit sequencing metadata. |
| `HSM (KEKs)` | Enforces the real security boundary: DB compromise ≠ KEK compromise; enables rewrap-based KEK rotation. |
| `Rotation Workers` | Rotations are long-running, failure-prone workflows; isolating them prevents read-path complexity. |
| `WORM Object Store` | The only credible “ground truth” audit store during/after compromise. |
| `Vault API` | Centralizes authZ + policy + envelope decrypt + consistent audit emission semantics. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| `Redis Cache` for token introspection + policy cache | **OIDC/JWT (humans) + SPIFFE/mTLS (workloads)** and in-process caches; optional `LISTEN/NOTIFY` for policy-version invalidation | Fewer moving parts, but revocation becomes “short TTL + reauth” unless you keep a revocation store. |
| Custom “Audit Stream” + “searchable index” (unspecified) | Use **Kafka/Kinesis/PubSub** as the audit bus, and **ClickHouse/OpenSearch** as the query store (WORM remains source of truth) | You operate/consume a standard pipeline instead of inventing one; still a non-trivial dependency. |
| Lease state in Postgres on every read | Make leases **conditional**: only write lease records for dynamic secrets / renewals; for static secrets return `(version, expires)` without durable lease rows | You lose perfect “who still uses N?” for static secrets unless you infer via audit analytics. |
| Bespoke rotation state machine in Postgres | Use **Temporal/Step Functions** for retries/timeouts/idempotency, with Postgres as data plane | Adds a platform dependency, but dramatically reduces “workflow correctness” burden. |
| “Fail closed if audit sink unreachable” + local disk buffer (with stateless API) | Put the buffer behind a **durable, shared queue** (Kafka/SQS) or make the API explicitly stateful (local WAL + sticky routing) | Cleaner semantics; otherwise “stateless API” and “local buffering” fight each other operationally. |

## Stress Test

### Failure Scenarios

1. **Postgres is down for 5 minutes**
   - Design’s answer: addressed partially (primary failure/promote), but not the “hard downtime” mode.
   - Recommendation: Strengthen — explicitly define behavior: reads/writes fail closed; return *actionable* errors; define whether *any* mode (e.g., break-glass-only) is allowed and how it’s audited.

2. **Audit pipeline is slow (not down)**
   - Design’s answer: “fail closed” + buffer to local disk with caps.
   - Recommendation: Strengthen — slow sinks create a self-inflicted outage. You need backpressure design: async publish with bounded queue + clear circuit-breaker thresholds + a durable shared buffer (or accept stateful API nodes).

3. **HSM throttling / partial outage during deploy storm**
   - Design’s answer: seal/fail closed; target “<5% reads hit HSM” but caching strategy isn’t specified.
   - Recommendation: Must strengthen — spell out how you hit 15k RPS with <5% unwraps (e.g., per-process in-memory cache of *unwrapped DEKs* with very short TTL + mlock/no-swap + strict telemetry), and be honest about the security trade-off under host compromise.

4. **Bad policy/config rollout locks everyone out (or opens access)**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen — add policy versioning + staged rollout + “shadow evaluation” (log-only) + rapid rollback; require 2-person approval for break-glass/policy broadening; keep an emergency, pre-audited break-glass path.

5. **Rotation worker bug revokes too early / rotates twice**
   - Design’s answer: idempotency keys + state machine, but fencing/concurrency details are light.
   - Recommendation: Strengthen — enforce single-flight with Postgres **advisory locks** (per secret) or equivalent; require monotonic state transitions; add invariants (“never revoke before overlap_window + min_leases_age”) and automated rollback hooks.

## Recommendations

### Must Fix
- Make the **audit buffering vs stateless API** story consistent (shared durable buffer or explicitly stateful ingestion).
- Define the **HSM avoidance strategy** (what’s cached, for how long, what hardening exists, and what happens under compromise).
- Reduce **read-path write amplification** by scoping durable leases to where they’re truly needed (dynamic secrets / renewals).

### Should Consider
- Replace token introspection + Redis with **OIDC/JWT + SPIFFE/mTLS** and policy-versioned caching; keep explicit revocation only where required.
- Use a proven workflow engine (Temporal/managed equivalent) for rotation to lower correctness and on-call burden.
- Specify the online audit query store explicitly (ClickHouse/OpenSearch/etc.) and define how it’s reconciled against WORM.

### Nice to Have
- Add a **policy simulator** and “why was access denied” tooling for 3am operations (with strict redaction).
- Add a **clock-skew strategy** for leases/tokens (server-time issuance, leeway, monotonic expiry checks).
- Define **multi-region DR** for audits (how you prove “no gaps” across failover).

## What's Working Well
- The leases + version pinning model makes rotation **observable, enforceable, and rollbackable**—that’s the standout design choice.
- Envelope encryption + HSM KEKs cleanly separates concerns and makes KEK rotation a **rewrap** problem, not a re-encrypt-the-world event.
- Treating audit integrity as a first-class security property (hash chain + WORM) is the right posture for incident credibility.