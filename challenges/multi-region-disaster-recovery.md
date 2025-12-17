## Elegance Check

### The Core Insight
Decoupling **data-plane cutover** (where traffic goes) from **authority-plane write fencing** (who is allowed to accept writes), then making “write authority” a **hard, auditable invariant** via a lease so DNS overlap can’t cause split-brain.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| `Write-authority lease` (external quorum) | Provides the only crisp invariant in gray failures: at most one writer, even during partitions and DNS overlap. |
| `Warm standby DB` | Makes RTO a capacity/automation problem, not a provisioning problem. |
| `Replication lag measurement + gating` | Turns RPO from “hope” into an enforceable safety check and a clear operator decision point. |
| `Traffic cutover automation` (DNS/GTM staged weights) | Reduces human steps under stress and supports progressive validation during cutover. |
| `Read-only/redirect behavior in old region` | Makes the overlap window safe and observable instead of an implicit risk. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom `DR Orchestrator + Lease` | Use an existing HA/failover controller (e.g., Postgres Patroni-style) with a proven distributed lock backend (etcd/Consul) and prebuilt workflows | Less bespoke logic, but you inherit constraints/opinions; cross-region tuning may be non-trivial. |
| External quorum store “not co-resident” (unspecified) | Use a *very small* “witness” footprint with a single-purpose strongly consistent store (e.g., a tiny Postgres used only for leases, or a managed strongly consistent KV) | Operationally simpler than running a full coordination system, but the witness becomes a new tier-1 dependency. |
| DNS/GTM as primary steering | If available, use a managed global L7 traffic manager/anycast front door for faster, more deterministic drain/cutover | Typically higher cost and more vendor coupling; adds a new control surface. |
| App-tier lease checks on write paths | Push fencing closer to the database: require a lease-bound credential/role for writes, or validate a fencing token in a DB function/guard table | More invasive DB/app integration, but reduces “forgotten code path” risk in apps. |
| “Serve reads from standby (optional)” | Start with standby **dark** (no reads) unless you need it; focus on promotion correctness first | You give up some read availability during primary impairment, but you reduce steady-state complexity and replication load. |

## Stress Test

### Failure Scenarios
1. **Lease/quorum store is down for 5 minutes**
   - Design's answer: not addressed
   - Recommendation: Strengthen  
   Add explicit behavior: default to “no new writer” (safe but impacts RTO), define whether an *existing* primary can continue writes during quorum outage (requires carefully defined lease renewal/grace), and alert on “cannot renew lease” well before expiry.

2. **Network partition: Region A can reach quorum; Region B can reach clients (or vice versa)**
   - Design's answer: partially addressed (lease blocks split-brain, DNS overlap acknowledged)
   - Recommendation: Strengthen  
   Define which signals are authoritative when traffic health conflicts with lease reachability. Add a “traffic-serving but read-only” mode for the region that can’t obtain lease, plus clear operator UX: “clients prefer B, but A holds lease.”

3. **Replication lag spikes above RPO, then primary dies**
   - Design's answer: addressed (block auto-failover, require explicit override)
   - Recommendation: Strengthen  
   Add a concrete “data loss estimate” method (e.g., by LSN/GTID gap) and define what happens to *in-flight* acknowledged writes (idempotency keys, replay strategy, customer messaging).

4. **Bad deploy/config enables writes without lease on one endpoint**
   - Design's answer: implied (“API requires a valid lease token”) but not hardened
   - Recommendation: Strengthen  
   Make this a defense-in-depth invariant: centralized middleware, integration tests, and preferably DB-side enforcement so a single misconfigured service can’t bypass fencing.

5. **Promotion succeeds, but DNS cutover is slow and old clients keep long-lived connections to Region A**
   - Design's answer: addressed (redirect/503 + Retry-After; “no lease, no write”)
   - Recommendation: Acceptable  
   Add one more practical detail: ensure *reads* in the old region are clearly marked (e.g., `X-Writer-Region`, `X-Read-Only`) so operators can quantify “stuck traffic” and support teams can debug clients.

## Recommendations

### Must Fix
- Specify the **lease system semantics**: renewal interval, TTL, clock/GC assumptions, what happens on renewal failure, and whether a primary can continue writes during brief quorum loss.
- Add **hard fencing beyond the app** (at least one): DB role/credential gating, DB guard table/function, or forced write shutdown of old primary (STONITH-style) to reduce reliance on “every code path checks the lease.”
- Define the **failover decision state machine** (cooldowns, hysteresis, abort/rollback conditions) so automation is predictable under flapping signals.

### Should Consider
- Replace/justify the custom orchestrator: either adopt a proven controller pattern/tooling, or keep it small by explicitly scoping it to “lease + promotion + DNS change,” pushing health aggregation and audit logging to standard observability tooling.
- Decide whether standby serves reads; if you keep it, document **read consistency expectations** (staleness bounds, monotonic reads per user/session, cache behavior).
- Tighten DNS overlap handling: prefer **regional hostnames** + explicit client retry policy for writes (even if only for first-party clients) to reduce dependence on redirects.

### Nice to Have
- A “DR readiness dashboard” checklist: current writer, lease TTL, replication lag p50/p99, standby capacity headroom, last successful drill, and “estimated stuck traffic” by resolver/ASN.
- A documented **failback** workflow that is explicitly “re-seed then switch,” with safeguards to prevent timeline/replication confusion.

## What's Working Well
- The design is honest about DNS limitations and builds for overlap instead of pretending TTL is a switch.
- The single-writer stance is a strong correctness simplifier for a small team, and the RPO/RTO targets are concrete and testable.
- Gating promotion on lag (with an explicit “accept data loss” decision) is exactly the kind of operational clarity that prevents 3am accidents.
- Calling out gray failures and requiring multi-signal corroboration is pragmatic and aligns with real incident patterns.