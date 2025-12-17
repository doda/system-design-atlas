## Elegance Check

### The Core Insight
Constrain “global truth” to a tiny, strongly consistent tuple (`owner_region`, `epoch`, handoff metadata), then use epoch-based fencing + a catch-up barrier so cart contents stay fast and regional without allowing split brain writes.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Cart Directory (linearizable) | The only place that can *prove* single-writer ownership and provide fencing (epoch monotonicity). |
| Epoch fencing on every write | Makes correctness a protocol property; prevents “stale region still accepts writes”. |
| Handoff barrier (`handoff_barrier_seq`) | Eliminates the lost-update window during cutover by forcing a complete prefix before new writes. |
| Regional Postgres (authoritative for owner) | Keeps steady-state latency low and operations boring (txns, idempotency, durability). |
| Idempotency keys | Makes retries safe; required for mobile/edge and partial failures. |
| Replicated read model (optional) | Only justified if you truly need low-latency reads in non-owner regions at scale. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Kafka “Replication Log” for warm reads + handoff assist | Start with **no cross-region replication**: non-owner reads are served via “read-through” to owner (with caching) and handoff always pulls from old owner | Higher cross-region read latency; but far fewer moving parts and on-call surface area. |
| Custom “Cart Directory” service | Use a proven linearizable store: **etcd/Consul/ZooKeeper** (leases, CAS) or a **managed strongly-consistent KV** | Less custom code, but you inherit its ops model/quotas and need careful client behavior (leases, retries). |
| Edge caches directory with TTL | Issue a **client “cart session token”** containing `(epoch, owner_region)` and refresh only on `409 EpochMismatch` | More explicit contract, fewer directory reads; requires token rotation/compat handling. |
| Handoff state in directory (`TRANSFERRING`) + custom janitor | Model handoff as a single CAS’d “handoff record” with an id/nonce + TTL | Simpler state machine; but you must define safe expiry/abort semantics. |
| Mutation log in Postgres + separate replication channel | Use **Postgres logical decoding/CDC** to feed replicas (if you keep replication) | Fewer systems than Kafka; but CDC across regions has its own failure/lag modes. |

## Stress Test

### Failure Scenarios

1. **Lost-update race between Step 1 and Step 2**
   - Design's answer: *not addressed explicitly*
   - Recommendation: **Strengthen (Must Fix)**. As written, there’s a critical gap: after Region A returns `handoff_barrier_seq`, Region A can still accept writes *before* the directory epoch increments. Those writes will be > barrier and get stranded/lost. Fix by making `PrepareHandoff` **quiesce writes** for `(user_id, epoch)` (reject/queue mutations), and return a `handoff_token` proving A is frozen. Step 2 becomes a directory CAS on expected epoch + token.

2. **Directory down for 5 minutes**
   - Design's answer: “existing owners continue under cached ownership + short lease TTL; fail closed after TTL; reads from replicas”
   - Recommendation: **Strengthen**. Make the lease story first-class: use directory-backed **leases with keepalive** (not just cache TTL). If directory is unreachable, owners naturally lose the lease and stop accepting writes, preventing “zombie owner” behavior.

3. **Network partition: Region A can’t reach Directory, but clients still hit Region A**
   - Design's answer: “fail writes closed when ownership cannot be verified beyond TTL”
   - Recommendation: **Acceptable if leases are real**. Without true leases, “periodic refresh” can allow writes during a partition longer than your refresh interval. Require a valid local lease for every write.

4. **Concurrent handoffs / flapping routing (two edges initiate A→B and A→C)**
   - Design's answer: *partially implied via directory transaction*
   - Recommendation: **Strengthen**. Require directory updates to be **compare-and-swap** on `(epoch, handoff_state)` and include a **handoff_id/nonce**; reject if a handoff is already in progress. Add hysteresis at Edge (don’t handoff on transient latency spikes).

5. **Owner outage during handoff while directory says `TRANSFERRING`**
   - Design's answer: abort and move ownership elsewhere using replicated snapshot; possible staleness
   - Recommendation: **Acceptable with explicit RPO**. Be honest about what “slightly stale” means: define the maximum acceptable rollback window and how you choose the recovery source (latest replicated snapshot vs last durable mutation log).

## Recommendations

### Must Fix
- Close the Step1→Step2 gap: `PrepareHandoff` must **freeze/serialize writes** for the old owner before returning the barrier, and Step 2 must CAS using a **handoff_token** (or directory-granted lease revocation) to guarantee no post-barrier commits slip in.
- Make ownership verification precise: replace “periodically refresh” with **directory leases** (or equivalent) and require a valid lease to accept any write for an epoch.
- Specify CAS semantics on directory writes (expected epoch/state) and define behavior for **duplicate/mismatched handoff attempts**.

### Should Consider
- Re-evaluate Kafka: if its main purpose is warm reads, start simpler (read-through to owner + caching) and add replication only when needed; if you keep it, document exactly-once vs at-least-once handling and dedupe strategy.
- Define mutation log retention and handoff guarantees: how long must Region A retain mutations to serve “pull to barrier”, and what happens if the barrier is older than retention?
- Tighten the client/edge contract: treat `epoch` as part of a “cart session” so mismatch handling is fast and doesn’t hammer the directory.

### Nice to Have
- Add explicit “checkout consistency” mode: reads that must be fresh (owner-only, or read-through) vs casual cart views that can be stale.
- Add a small state-machine diagram/table for handoff states + transitions + timeouts to make the protocol reviewable.

## What's Working Well
- Great decomposition: you isolated the only thing that truly needs strong consistency (ownership) and kept the data path regional.
- The barrier concept is the right mental model for cutover correctness (prefix completeness), and it’s much more honest than “merge later”.
- Operational notes are practical (mismatch metrics, stuck handoffs, a truth/debug endpoint); that’s exactly what makes this ownable in production.