## Elegance Check

### The Core Insight
Making the internal **append-only double-entry ledger** the only durable truth, and treating PSP outcomes (API responses, webhooks, settlement files) as **external facts that reconcile into compensating postings**—so retries/ambiguity never directly mutate “money truth.”

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Ledger DB (Postgres) | Auditable, deterministic money truth; supports corrections via compensating entries. |
| Payments API state machine | Centralizes invariants: idempotency, valid transitions, and when ledger postings are allowed. |
| Inbox (webhook dedupe) | Converts at-least-once/duplicated PSP delivery into exactly-once internal fact processing. |
| Outbox (durable intent) | Prevents “DB wrote but PSP call didn’t / PSP call happened but DB didn’t” gaps; enables safe replay. |
| Reconciliation worker | Settlement is the long-tail truth; required for fees/FX/chargebacks and drift detection. |
| PSP Connector | Isolates PSP quirks and keeps PSP idempotency stable and testable. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| “Outbox Queue” as a separate component | Keep outbox in Postgres and run a poller (or LISTEN/NOTIFY) that executes directly (no external queue) | Less infra; harder to smooth spikes / backpressure; LISTEN/NOTIFY is best-effort so still need polling. |
| Custom state orchestration | Use a workflow engine (Temporal) for attempt lifecycle + retries + timeouts | Faster correctness; adds a major dependency and operational surface area. |
| “Order per-payment when possible” in webhook ingest | Use DB row locking (`SELECT … FOR UPDATE`) or advisory locks keyed by `payment_attempt_id` to serialize transitions | Very simple; can reduce concurrency on hot keys; needs careful timeout handling. |
| Reconciliation matching implied | Store a normalized “PSP reference map” table (psp_charge_id, auth_id, capture_id, payout_id) with unique constraints | Clearer matching; extra write path and schema. |
| Ledger used for balances implicitly | Maintain explicit derived projections (materialized views / tables) for “available/held/settled” per merchant & currency | Better performance and APIs; adds projection lag and backfill complexity. |

## Stress Test

### Failure Scenarios
1. **Postgres down for 5 minutes**
   - Design’s answer: partially addressed (“API accept + durable recording” implies DB is required, so accept likely fails)
   - Recommendation: Strengthen — be explicit: if Postgres is unavailable, return `503` (no “accept without durability”); add runbook for backlog catch-up and ensure outbox/inbox workers stop safely.

2. **Network partition: Payments API ↔ PSP (timeouts/unknown outcomes)**
   - Design’s answer: addressed (`PENDING_EXTERNAL`, wait for webhook/query/recon)
   - Recommendation: Acceptable — add hard limits: when to auto-query PSP, exponential backoff, and when to escalate to manual review to avoid indefinite limbo.

3. **One component slow but not failing (webhook ingest lag or outbox lag)**
   - Design’s answer: partially addressed (metrics like outbox lag/pending aging)
   - Recommendation: Strengthen — define SLO-based automation: e.g., if webhook lag > X, switch to active PSP polling; if outbox lag > Y, shed non-critical work (e.g., evidence uploads) to protect core capture/refund processing.

4. **Bad config deploy (wrong PSP endpoint/keys, wrong fee schedule, wrong FX rounding)**
   - Design’s answer: not addressed
   - Recommendation: Strengthen — add config versioning + canaries per PSP account, and “ledger posting guardrails” (limits/thresholds) so a bad fee config can’t silently post massive adjustments.

5. **3am human error (engineer retries a timed-out capture manually)**
   - Design’s answer: addressed as a “golden rule,” but relies on discipline
   - Recommendation: Strengthen — enforce in tooling: a “safe retry” command that first checks webhook/inbox/PSP query/recon and only then enqueues an outbox action; block ad-hoc replay without a recorded reason code and peer approval.

## Recommendations

### Must Fix
- Clarify the claim: this is **at-least-once processing with idempotent handlers**, not true exactly-once across PSP boundaries; document the precise guarantees per boundary (API, outbox worker, webhook ingest, recon).
- Define **ledger invariants and posting schemas per transition** (authorize/partial capture/refund/chargeback) including multi-currency and FX rate source-of-truth; ambiguity here is where “financially correct” designs usually fail.
- Specify **concurrency control** for state transitions (locks/advisory locks/version columns) so two workers/webhooks can’t race and produce double postings.

### Should Consider
- Collapse “Outbox Queue” into a simpler first version: Postgres outbox + poller, and introduce an external queue only when backpressure demands it.
- Add a small **reference-mapping layer** (unique constraints on PSP identifiers) to make reconciliation matching deterministic and to prevent “same PSP event maps to two internal attempts.”
- Make “manual ops” a first-class workflow: reason-coded compensating entries, approval gates, and audit trails integrated with runbooks.

### Nice to Have
- Separate **derived balance projections** (available/held/settled) from the journal early to keep API latency stable while the journal grows.
- Define a clear **data retention + reprocessing** policy (how long inbox is kept, how to re-run recon safely, how to rebuild projections).

## What's Working Well
- The separation of **money truth (ledger)** from **money movement (PSP integration)** is the right abstraction and sets you up for disputes/fees/settlement reality.
- The timeout stance (“unknown, not failed”) and inbox/outbox approach targets the real failure modes instead of the happy path.
- Operational thinking is strong: you call out the “never retry blindly” rule and the right metrics (lag, pending aging, drift variance).