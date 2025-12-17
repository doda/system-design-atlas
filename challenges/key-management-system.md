## Elegance Check

### The Core Insight
Envelope encryption + **key identity (alias) with versioned CMKs** turns “rotation” into a safe metadata flip and makes “migration” a **rewrap-of-DEKs** problem, keeping the HSM off the bulk-data path.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| HSM Cluster | Root-of-trust that keeps CMK material non-exportable and constrains the blast radius of a KMS/API compromise. |
| KMS API (stateless) | Centralizes policy enforcement + idempotency + consistent audit emission; scales independently of HSM capacity. |
| Postgres Metadata | Strong consistency for alias→primary version, state machine, idempotency tokens, and policy storage. |
| Rotation Worker | Makes rotation/rewrap operationally boring and keeps latency-sensitive APIs predictable. |
| Tamper-evident Audit Store | Compliance/forensics-grade trace of every cryptographic/admin action; must survive attacker-in-the-control-plane scenarios. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate “Audit Log” pipeline + indexing + WORM storage | **Transactional outbox in Postgres** (append-only audit table in same tx as key ops) + async export to WORM S3/Object Lock | Strong coupling is simpler and safer; Postgres becomes even more critical (but it already is). |
| In-memory policy cache (unspecified invalidation) | Postgres `LISTEN/NOTIFY` for **cache invalidation** keyed by `key_id/policy_version` | Adds a DB channel dependency; still need fallback when notifications drop. |
| ReEncrypt described as “unwrap then rewrap” | Prefer **HSM-native rewrap** (unwrap+wrap without releasing plaintext to KMS memory) | Requires HSM support / vendor-specific APIs; otherwise be explicit that plaintext DEK exists in KMS RAM. |
| Custom “ABAC-lite” evaluator | Use a proven library/model (e.g., **Cedar**, OPA with a constrained policy set, or managed IAM-style statements) while keeping expressiveness limited | More dependencies; but fewer footguns and better tooling (tests, explain, diff). |
| Rotation worker as a bespoke job system | Use Postgres row-locking + `SKIP LOCKED` as the queue, with **advisory locks** for singleton tasks | Less throughput than a dedicated queue; usually fine for rotation/rewrap workloads. |
| “Fail closed if Postgres down” as a blanket rule | Add an explicit **degraded-read mode**: allow `DecryptDataKey` for a tiny “hot set” with short-lived, signed metadata snapshots | Improves availability but weakens “always consult source of truth”; needs tight time bounds + loud alerting. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: fail closed; “small in-memory cache for metadata reads but never for bypassing state transitions”
   - Recommendation: Strengthen — define *exactly* what “fail closed” means per operation (at least `DecryptDataKey` vs admin), and specify cache rules (TTL, required freshness, how disables/deletes propagate).

2. **HSM is slow (not down) and p99 balloons**
   - Design’s answer: rate-limit per op; shed rewrap first; prioritize decrypt
   - Recommendation: Strengthen — add backpressure semantics (queue vs reject), tenant fairness, and an explicit capacity model (“HSM ops/sec budget” → max RPS per API) so 10x traffic becomes controlled degradation, not cascading timeouts.

3. **Audit sink is degraded/unavailable**
   - Design’s answer: API only continues if audit is durably accepted (local WAL/spool); otherwise reject
   - Recommendation: Strengthen — clarify what “durably accepted” is (fsync to local disk? replicated?), how you prevent spool tampering, and how you drain without reordering/duplication (hash-chain + sequence gaps + checkpointing).

4. **Network partition between KMS API and HSM (or one AZ isolated)**
   - Design’s answer: partial HSM outage handling at AZ level
   - Recommendation: Strengthen — define routing/failover policy (stickiness vs any-AZ), what happens to in-flight requests, and how you prevent “split brain” during key creation/dual control workflows.

5. **Bad policy/config deploy accidentally permits decrypt**
   - Design’s answer: “ABAC-lite” for explainability; break-glass is noisy
   - Recommendation: Strengthen — require policy change safety rails: staged rollout/canary, automated diff checks (“this change expands principals/actions”), and an emergency “deny-all” kill switch that is itself dual-controlled and audited.

## Recommendations

### Must Fix
- Make `ReEncrypt` boundary honest: either mandate **HSM rewrap** (plaintext never reaches KMS memory) or explicitly document plaintext DEK exposure in KMS RAM and how it’s protected (process isolation, memory handling, crash dumps, debugging).
- Specify **audit durability and tamper evidence** end-to-end (hash chain, signed checkpoints/anchors, replay/dup detection, exact semantics of “accepted before response”).
- Define cache semantics for metadata/policy: **invalidation, TTL, and failure behavior** so “fail closed” remains true under partitions and stale caches.

### Should Consider
- Collapse audit into a Postgres outbox + WORM export to reduce moving parts while increasing correctness.
- Add explicit **capacity math** (HSM ops/sec, concurrency limits, retry budgets) and per-tenant fairness to avoid self-inflicted outages under peak/retry storms.
- Provide a safer API variant: `GenerateDataKeyWithoutPlaintext` (many real KMSes do) for workloads that can avoid handling raw DEKs.

### Nice to Have
- Formalize key state machine invariants (e.g., “cannot disable primary unless another enabled version exists”) and enforce with DB constraints/transactions.
- Add “decision ID” to every authZ evaluation (policy version, inputs hash) to make incident forensics and rollbacks faster.

## What's Working Well
- The **two-plane split** (HSM protects keys, not data) is the right simplicity lever for performance and operability.
- Versioned aliases + atomic primary flip is a clean, low-coordination rotation story.
- Treating `ReEncrypt` as “rewrap keys, not terabytes” is the right operational framing.
- You explicitly prioritize **decrypt availability** over rewrap during incidents and acknowledge Postgres as a correctness dependency (good design honesty).