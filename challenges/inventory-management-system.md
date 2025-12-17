## Elegance Check

### The Core Insight
Use Postgres as the single authority and make “reserve/commit/release” nothing more than idempotent state transitions guarded by one atomic predicate: `on_hand - reserved >= qty`.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Postgres | Single consistent authority for the oversell gate and state machine; transactional rollbacks are your safety net under retries/failures. |
| `reservations` table | The idempotency anchor + audit trail; lets you answer “what happened?” and makes commit/release exactly-once at the business level. |
| Conditional `UPDATE inventory ... WHERE (on_hand - reserved) >= qty` | The simplest correct oversell prevention primitive; avoids distributed locks and read-modify-write races. |
| Expiration worker | Turns “time” into a real accounting transition; keeps counters and business state aligned. |
| Read cache | Keeps read-path cheap without polluting correctness; good separation of concerns. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate “Queue” for expiration | Skip the queue and have the worker poll Postgres using an index on `(state, expires_at)` plus `FOR UPDATE SKIP LOCKED` batching | Slightly more DB load; fewer moving parts and easier ops (often worth it at your write rates). |
| “Mark reservation RELEASED (or delete) on OOS” | Add an explicit terminal state like `REJECTED` (out-of-stock) and persist it; never delete | More states, but correct idempotency semantics (same key ⇒ same outcome) and better debugging. |
| Custom `version` on `inventory` | Drop it unless you’re using it for cache invalidation/CDC; rely on row locks + `updated_at` | Lose a convenient monotonic token unless you implement it elsewhere; less schema baggage. |
| Dedicated Inventory Service as a deployable | If the team is small, keep it as a module in the API (same DB invariants), extract later | Less isolation/blast-radius control; much simpler deploy/on-call surface early on. |
| Per-reservation expiration work item | Set-based expiry: select N expired reservations, transition them, then apply aggregated `reserved` decrements per SKU | More complex worker logic; reduces hot-SKU thrash and DB write amplification. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: “out of stock” as safety fallback; correctness prioritized
   - Recommendation: Strengthen (explicit degraded-mode behavior: cache-only reads allowed, writes fail fast with clear user messaging; add runbook + circuit breaker so you don’t pile retries and extend recovery)

2. **Network partition / client retries cause duplicate reserve+commit calls**
   - Design’s answer: idempotency keys + reservation row as anchor
   - Recommendation: Strengthen (define idempotency key scope: include `operation_type` and bind to `sku, qty, cart_id/user_id`; reject mismatched replays to avoid “same key, different payload” corruption)

3. **Expiration worker lags for an hour (backlog)**
   - Design’s answer: detect lag; scale workers; commit checks `expires_at`
   - Recommendation: Strengthen (make “effective availability” subtract *only unexpired* holds for reads that matter, or add a lightweight API-side repair: if `expires_at <= now()` during reserve/commit paths, opportunistically transition/release under lock)

4. **Hot SKU contention (10x traffic spike on one SKU)**
   - Design’s answer: timeouts + retry; rate-limit per SKU; consider per-SKU queuing later
   - Recommendation: Strengthen (define lock ordering to prevent deadlocks; consider a Postgres-only smoothing option like per-SKU advisory locks *only for the hottest SKUs* to bound lock waits and make tail latency predictable)

5. **Bad deploy / bug causes incorrect counter mutation**
   - Design’s answer: reconciliation job; auditability
   - Recommendation: Strengthen (add “invariant monitors” that continuously sample `inventory.reserved` vs sum(ACTIVE) and page fast; keep a minimal admin repair tool/runbook for recompute-and-fix by SKU)

## Recommendations

### Must Fix
- Make idempotency semantics airtight: idempotency key must be scoped and validated against request payload; don’t “delete on OOS” if you promise idempotency.
- Specify transaction/lock ordering (e.g., always lock `reservations` then `inventory` by SKU) to avoid deadlocks under concurrent commit/release/expire.
- Add the missing indexes that make the design viable: at minimum `reservations(state, expires_at)`, and likely `reservations(idempotency_key)` (already unique) plus `reservations(sku, state)` for reconciliation.

### Should Consider
- Remove the expiration queue unless you truly need it; Postgres polling with `SKIP LOCKED` is often the most elegant “one system” solution here.
- Reduce write amplification on expiry by batching and aggregating decrements per SKU (especially if holds are high-volume).
- Define the cache coherency story explicitly (outbox/CDC vs write-through vs short TTL) so “availability badges” don’t become a mystery during incidents.

### Nice to Have
- Add a `RECONCILING`/“repair in progress” operational state for SKUs during manual fixes (prevents churn while you correct).
- Document clock assumptions (DB time is source of truth; avoid app-server clock skew affecting expiry decisions).
- Consider `COMMITTED` linking to payment intent ID for simpler payment/inventory reconciliation.

## What’s Working Well
- The design cleanly separates strict correctness (write path) from performance (read cache/eventual consistency).
- The reservation state machine + conditional counter update is the right “boring invariant” and scales well for correctness under retries.
- Failure-mode thinking is already pragmatic (undersell > oversell), and you’ve called out the real bottlenecks (hot SKUs, expiration lag, payment/commit mismatch).