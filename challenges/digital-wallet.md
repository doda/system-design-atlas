## Elegance Check

### The Core Insight
Treat money movement as an **immutable, double-entry journal** and make `balance` a **derived projection**; correctness becomes “journal is right ⇒ everything else is repairable.”

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Wallet Service | Single semantics owner (idempotency, invariants, locking discipline) |
| Postgres Ledger (transfers + entries) | One atomic transaction boundary you can audit and replay |
| Balance projection table | Makes reads O(1) while keeping the journal authoritative |
| Transactional outbox | Couples “ledger committed” with “emit side effects” without pretending to be exactly-once |
| Metrics/alerts + reconciliation | Turns silent corruption into detectable, recoverable incidents |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Redis cache for balances | Start with Postgres `wallet_balances` + (optional) read replicas | Slightly higher p99 reads; much simpler ops until you prove Redis is needed |
| Transfer `PENDING` state + reaper | Make transfers “complete by construction”: insert transfer + entries + projection in one txn; infer completion from presence of entries | Harder to model async/long-running workflows; fewer zombie states and less recovery logic |
| Polling outbox publisher | Use Postgres `LISTEN/NOTIFY` to wake the publisher (still backed by outbox table) | Extra moving part in DB; lower latency + less polling load |
| Row locks vs advisory locks (either/or) | Prefer **one** locking scheme (typically row lock on `wallet_balances`) | Advisory locks are easy to misuse; row locks are visible and play well with SQL tooling |
| Ledger history ordering by `created_at` | Use stable cursor: `(monotonic_id)` or `(created_at, id)` everywhere | Slight schema/index cost; eliminates pagination bugs and “missing/duplicated rows” |

## Stress Test

### Failure Scenarios

1. **DB is down for 5 minutes**
   - Design’s answer: implicit “writes fail; retries via idempotency”
   - Recommendation: Strengthen — define client-visible error semantics (retry-after), circuit breaking, and what happens to outbox backlog on recovery.

2. **Two concurrent transfers from same wallet + one to same counterparty**
   - Design’s answer: row lock on sender prevents double-spend
   - Recommendation: Strengthen — lock ordering across *both* wallets to avoid deadlocks (lock wallets in increasing `wallet_id`, or advisory lock on `(min,max)`), and define behavior under contention (queue vs fast-fail).

3. **Service crashes after inserting `PENDING`**
   - Design’s answer: reaper completes/marks failed
   - Recommendation: Acceptable, but consider simplification — if everything is truly one DB txn, you shouldn’t be able to persist `PENDING` without the ledger effects; if you can, you’ve introduced a second phase (and you should document why).

4. **Redis is down / network-partitioned**
   - Design’s answer: not addressed explicitly (Redis “never source of truth”)
   - Recommendation: Strengthen — specify fallback read path (Postgres projection), cache invalidation strategy (write-through + TTL), and how you prevent stale-balance UX from causing retries/duplicate attempts.

5. **Bad deploy changes transaction semantics**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — pin required isolation/locking behavior with invariants + tests (e.g., concurrent spend property test), and add a “canary transfer”/shadow checker that alarms on projection-vs-journal drift.

## Recommendations

### Must Fix
- Define **deadlock-free locking** when touching two wallets (deterministic lock order) and what you do under hot-wallet contention.
- Clarify idempotency scope: include a **client identifier** (or globally unique key) so `(from_wallet_id, idempotency_key)` can’t collide across clients/environments.
- Make history queries **stably ordered** with cursor-based pagination using a monotonic key (not just `created_at`).
- Enforce immutability practically: DB permissions (no UPDATE/DELETE on ledger tables), and constraints/invariants (e.g., per `transfer_id` exactly two entries; amounts/currency match; debit/credit net to zero).

### Should Consider
- Start without Redis (or gate it behind proven read pressure); keep the “boring core” = Postgres + projection + outbox.
- Use `LISTEN/NOTIFY` to simplify outbox publishing latency/efficiency while keeping the outbox table as the durable truth.
- Store money as integer minor units (`BIGINT`) and make currency handling explicit (either “wallet per currency” or `(wallet_id, currency)` everywhere).

### Nice to Have
- A first-class “explain transfer” endpoint/view (you already called this out—worth prioritizing early).
- Operational runbooks: “DB failover”, “rebuild projection for wallet”, “outbox backlog drain”, “hot wallet mitigation”.
- A “high-risk wallet” mode: stricter rate limits / forced serial processing when contention or fraud signals spike.

## What’s Working Well
- The design is honest about reality: **retries happen**, “exactly once” is a lie outside the DB, and auditability matters.
- Using a **transactional outbox** is the right kind of boring: simple, provable, and operable.
- Treating balances as a **projection** (with reconciliation + rebuild) is the right long-term posture for billions of journal rows.
- The operational hooks (drift detection, negative-balance alarms, restore drills) show good production instincts.