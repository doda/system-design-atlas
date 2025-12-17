```markdown
## Elegance Check

### The Core Insight
Modeling reservations as **time-bucketed leases** so expiration becomes a *pure function of time* (not a background process) is the standout idea—clean invariants, bounded state, and no “cleanup lag” correctness risk.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Spanner (global serializable tx) | Makes “zero oversell globally” a single, defensible guarantee instead of a reconciliation story. |
| Time-bucketed reservation accounting | Eliminates correctness dependence on TTL/sweepers; bounded per-stripe state. |
| Hot-SKU stripes | The only practical way to reduce single-row contention while keeping strict correctness. |
| Reservation record + idempotency | Turns retries into safe replays; enables clean checkout semantics. |
| Gateway fairness / throttling | Prevents retries/bots from becoming a self-inflicted DB outage. |
| Order Events stream | Decouples downstream work from checkout latency and failure domains. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| “Increase stripe count” during an incident | **Pre-split** hot SKUs into a large fixed max (e.g., 256/1024) and just “activate” more in the picker | More rows up front; much simpler ops (no live reshard). |
| Random stripe + bounded retries | “Power-of-two choices” + in-memory **stripe fullness hints** (best-effort) | Slightly more logic; materially fewer abort/retry storms near sell-out. |
| Buckets stored inline as `buckets[0..9]` | Explicit columns (`b0_epoch,b0_qty...`) or a `stripe_bucket` table | Columns: ugly schema but fast; table: more rows/reads, clearer writes. |
| Reservation expiry logic implied by minutes | Define lease validity precisely on **timestamps**; minute buckets only for accounting | A bit more spec work; prevents boundary bugs and surprises. |
| Payment “consume then capture, maybe re-activate” | Explicit **saga states** (`ACTIVE -> ALLOCATED -> PAID/FAILED`) + outbox-driven retries | More states, but far fewer edge-case footguns and 3am ambiguity. |
| “No sweeper” overall | Still use Spanner **TTL** to delete old `reservation` rows (after idempotency window) | Not used for correctness; just keeps tables bounded. |

## Stress Test

### Failure Scenarios

1. **Minute-boundary / lease validity edge (commit delayed past expiry)**
   - Design's answer: partially addressed (uses DB time; checks `expires_at <= now`)
   - Recommendation: **Strengthen** — define: “reservation is valid iff `commit_ts < expires_at`” (or equivalent) and align bucket window to `expires_at > now`. As written, the bucket window `[now_minute, now_minute+9]` conflicts with `expiry_minute = now_minute + 10` (off-by-one risk).

2. **Hot SKU contention causes ABORT storms (Spanner serializable retries)**
   - Design's answer: addressed (stripes, monitoring, rate limits)
   - Recommendation: **Strengthen** — require client/server exponential backoff with jitter on `ABORTED`, and make the gateway prefer *queue/deny* over “let retries hit DB”. Also call out how many stripes are needed for worst-case (50k RPS on one SKU) and how you’ll avoid “retry amplification” near sell-out.

3. **Stripe scaling mid-launch (ops tries to “increase stripe count”)**
   - Design's answer: mentioned, but not explained operationally
   - Recommendation: **Strengthen** — increasing stripes isn’t free if `total_units` is already split. Pre-splitting is the elegant way: allocate units across a large fixed stripe set at T-0; later you only change routing, not data.

4. **Payment/provider outage or partial failure**
   - Design's answer: addressed conceptually (ordering + idempotency; refund/revert idea)
   - Recommendation: **Strengthen** — “mark reservation ACTIVE again” after decrementing buckets / incrementing sold is dangerous without a crisp state machine. Prefer: (a) authorize first, (b) transactionally move to `ALLOCATED` (inventory committed), (c) capture async with retries; on capture failure, compensate by releasing allocation if still within policy, otherwise cancel+refund with clear business rule.

5. **Large qty reservations (qty=k) when inventory is fragmented across stripes**
   - Design's answer: not addressed
   - Recommendation: **Strengthen** — decide and document: either (a) enforce `qty <= per_stripe_max` (and size stripes accordingly), or (b) allow a single “reservation” to span multiple stripes (more complex but correct), or (c) reject large qty during launch mode.

## Recommendations

### Must Fix
- Specify exact **time semantics** (timestamp vs minute), including boundary conditions, and make bucket-window math consistent with `expires_at > now` and transaction commit behavior.
- Define a clear **reservation/checkout state machine** (including payment failure paths) that never relies on “best effort re-activate” after inventory has been mutated.
- Make stripe ops realistic: adopt **pre-splitting** (or explicitly describe a safe reshard procedure) and include a sizing rule-of-thumb for worst-case hot SKU throughput.
- Address multi-item carts: whether checkout is **atomic across SKUs**, and if so, specify lock/ordering strategy to avoid deadlocks and tail-latency blowups.

### Should Consider
- Add an explicit **cancel/release** flow (idempotent) so users removing items don’t cause avoidable under-selling for 10 minutes.
- Replace random retries with a smarter picker (power-of-two + hints) and make backpressure a first-class “launch mode” feature.
- Use Spanner TTL (or archival) for old `reservation` rows to keep storage and indexes bounded without reintroducing correctness dependence on cleanup.

### Nice to Have
- Document invariants formally (per stripe and per reservation) and list the exact queries/rows touched per operation for capacity planning.
- Add an “oops-proof” runbook for 3am: stripe activation, gateway tightening, and safe kill-switches (disable reserve vs disable checkout vs disable payment capture).

## What's Working Well
- The design is honest: it prioritizes correctness and explicitly accepts higher write latency—good architectural clarity.
- The time-bucket lease approach is a genuinely elegant way to avoid the classic “TTL job drift” trap.
- You isolate inventory truth to one service/DB boundary and treat idempotency as a first-class requirement.
- You’ve already anticipated the operational reality (hot keys, retry storms, rate limits) instead of pretending they won’t happen.
```