## Elegance Check

### The Core Insight
A single per-ledger committer that (1) assigns canonical order and (2) produces a signed, hash-linked block chain gives you “one history” + audit proofs, while keeping the rest of the system horizontally scalable and boring.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Ledger Committer | Containment of total ordering + proof generation; the only place that must be “high assurance.” |
| Postgres | Best place to enforce double-entry invariants and idempotency with transactions + constraints. |
| External Anchoring (concept) | Protects against “superuser rewrote history” by making divergence detectable outside your control plane. |
| Read Replica | Separates read load and export/analytics from write latency and vacuum/partition churn. |
| Queue (if non-PG) | Absorbs spikes and makes backpressure explicit, preventing DB timeouts as your throttle. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Dedicated Queue component | Use Postgres as the queue: `entry_intents` table + `SELECT … FOR UPDATE SKIP LOCKED` workers, optional `LISTEN/NOTIFY` wakeups | Fewer moving parts; increases PG write amplification and requires careful partitioning/retention of intents. |
| Separate “Anchor Service” | Make anchoring an async loop inside the committer (or a single cron-like worker) that reads unanchored blocks | Reduces service count; slightly couples failure domains (anchoring bugs share deploy path with committer unless isolated). |
| Object store for “Merkle trees / proof data” | Store per-block Merkle nodes (or just leaf hashes) in Postgres `bytea`/TOAST; serve proofs from DB | Fewer systems; DB bloat and hot-path impact if proof reads are frequent or large. |
| Advisory lock vs head row | Prefer a `ledger_heads` row with `SELECT … FOR UPDATE` + optimistic `version`/`prev_block_hash` check | Clearer correctness than “magic locks”; slightly more schema/state to manage. |
| Custom proof format | Use a standardized transparency log / TSA first (e.g., RFC3161 receipts) and treat “public chain anchoring” as optional | Less bespoke crypto plumbing; weaker “public verifiability” story unless you pick a public log. |

## Stress Test

### Failure Scenarios
1. **Primary DB is down for 5 minutes**
   - Design’s answer: queue buffers; committer pauses; resumes from head.
   - Recommendation: Strengthen — define hard behaviors: API returns `202` only if durably queued; otherwise `503` with retry-after. Also specify what happens to idempotency keys during outage (must survive process restarts and queue retries).

2. **Queue is at-least-once and reorders/duplicates messages**
   - Design’s answer: “dedupes” + idempotent by `client_request_id` (implied).
   - Recommendation: Strengthen — make dedupe a *DB uniqueness property*, not committer memory: unique index on `(ledger_id, client_request_id)` and make the insert path return the existing `entry_id/seq_no/block_id` on conflict.

3. **Network partition: API can enqueue but committer can’t reach Postgres (or vice versa)**
   - Design’s answer: not explicitly addressed.
   - Recommendation: Strengthen — decide if the queue is the source of truth for “accepted” (then you need durable, observable enqueue semantics) or if Postgres is (then you should consider PG-queue to avoid split-brain acceptance). Explicitly document client-visible states: “received”, “committed”, “proof available”, “anchored”.

4. **Proof publication succeeds but DB write is rolled back (or DB commit succeeds but proof publish fails)**
   - Design’s answer: covers “commit then publish; publish retried idempotently.”
   - Recommendation: Acceptable if you enforce ordering: only publish artifacts derived from committed `block_id` and make publishing idempotent by content-address (`block_hash` key). Consider an outbox table in Postgres (even if using an external queue) for “publish block X” tasks.

5. **Bad config / 3am operator mistake (unsafe migration, dropped partition, role granted UPDATE)**
   - Design’s answer: revoke UPDATE/DELETE, WORM backups, continuous verifier, anchoring.
   - Recommendation: Strengthen — add “guardrails that fail closed”: migration pipeline that refuses DDL touching ledger tables without a break-glass process; periodic permission drift checks; and a documented incident runbook for verifier mismatch (what to freeze, what evidence to preserve, how to re-anchor).

## Recommendations

### Must Fix
- Specify the *idempotency contract* precisely and enforce it in Postgres (unique constraint + deterministic response on retry); don’t rely on committer-side dedupe.
- Define the exact acceptance semantics around the queue: when you return success to clients, what is guaranteed to be durable, and how clients observe eventual commit/proof.
- Nail canonicalization: define `entry_canonical_bytes` deterministically (field ordering, encoding, normalization, versioning) and include a `format_version` in hashed/signed material to avoid “same entry, different bytes” failures years later.

### Should Consider
- Consider collapsing the queue into Postgres (intents table + `SKIP LOCKED`) to reduce operational surface area, especially for a small team.
- Make block production parameters explicit (max entries, max bytes, max time) and design for “partial blocks” on low traffic without breaking audit/export assumptions.
- Balance reads at 10k/s: commit to a read model (e.g., `account_balances` updated per block + optional snapshots) and specify staleness/consistency rules for “as-of T” vs “as-of now.”

### Nice to Have
- Key rotation story: how `signer_key_id` maps to verifiable public keys over time, and how you re-sign (or don’t) old blocks.
- Poison-message handling: malformed intents, permanent constraint failures, and a quarantine path that preserves auditability without blocking the shard.
- A single “ledger state machine” view for operators: head block, queue lag, unpublished blocks, unanchored blocks, replica lag.

## What’s Working Well
- The “small provable core” framing is excellent: total order + cryptographic chain in one place, invariants enforced in Postgres.
- Fork prevention is treated as the real problem (not “hash rows”), and the design uses transactional atomicity correctly.
- The threat model is refreshingly honest (privileged operator mistakes) and the verifier + external anchor direction is the right response.
- The trade-offs are clearly stated and consistent with the goals (auditability over write parallelism).