```markdown
---
title: "Cross-Region Shopping Cart"
category: "Strategic Problems"
difficulty: "Hard"
tags: ["multi-region", "consistency", "split-brain", "fencing-tokens", "handoff", "session-migration"]
---

## Overview

This system provides a low-latency shopping cart across multiple regions while preserving correctness when a user “moves” mid-session (DNS shift, mobile handoff, VPN, retries) and multiple regions receive traffic.

Global truth is constrained to one tiny record per cart: `(owner_region, epoch)` plus a lease that proves the owner is still active. Cart contents stay regional and fast in Postgres. Every write carries the current epoch and is accepted only by the region that holds the active lease for that epoch.

When a user starts sending traffic to a new region, ownership moves via an explicit handoff: the old owner freezes writes and emits a barrier sequence, the directory fences the old owner by bumping the epoch, the new owner catches up to the barrier, then writes resume. This makes split brain impossible at the data layer.

## What Makes This Hard

The only hard part is cutover correctness: ownership must move between regions without ever having two writers and without losing the tail of updates.

## Requirements

### Functional Requirements
- Maintain a single logical cart per user across regions.
- Prevent silent lost updates during region changes, retries, and client-side parallelism.
- Provide idempotent cart mutations (network retries must not duplicate).
- Support explicit handoff when user starts sending traffic to a new region.
- Writes must be correct; non-owner reads proxy to the owner.

### Scale Targets
- 10M DAU, 1M peak concurrent sessions.
- Peak 100k cart ops/sec globally (reads + writes), peak 20k writes/sec.
- P99 latency targets:
  - Same-region write after ownership established: 80–120ms.
  - First write immediately after region change (includes handoff): 250–500ms.
- Cart size: median 8 items, P99 50 items.

## Key Design Decisions

- **Decision 1: Single-writer carts enforced by a global directory with leases**
  - Chose: a linearizable KV (etcd/Consul/managed) storing `{owner_region, epoch, lease_id, handoff_*}`.
  - Why: the only global coordination is ownership; everything else stays regional.

- **Decision 2: Every write is fenced and idempotent**
  - Chose: every mutation carries `epoch` + `idempotency_key`; the owner must hold the active directory lease to accept writes.
  - Why: retries are safe, and stale regions cannot commit.

- **Decision 3: No cross-region replication for carts**
  - Chose: non-owner reads proxy to the owner; handoff catch-up always pulls directly from the old owner.
  - Why: fewer moving parts; the only cross-region mechanism is the handoff.

## Architecture

```mermaid
flowchart LR
  C[Client] --> E[Edge/API]
  E --> D[Cart Directory (linearizable + leases)]
  E --> CSA[Cart Svc (Region A)]
  E --> CSB[Cart Svc (Region B)]
  CSA --> DBA[(Cart DB A)]
  CSB --> DBB[(Cart DB B)]
  CSB <--> CSA
```

### Components

- **Edge/API**
  - Routes requests using a client-carried cart session token `(owner_region, epoch)`; refreshes from the directory on `409`.
  - Attaches `epoch` + `idempotency_key` to every mutation request.

- **Cart Directory (linearizable + leases)**
  - Stores per user: `owner_region`, `epoch`, `lease_id`, and minimal `handoff` metadata.
  - Provides compare-and-swap updates so only one handoff can win.

- **Cart Service (per region)**
  - Serves reads from local DB only when it is owner; otherwise proxies reads to the owner.
  - Accepts writes only if it holds the active directory lease for the current epoch.
  - Maintains an ordered per-cart mutation sequence (`cart_seq`) for handoff barriers.

- **Cart DB (Postgres per region)**
  - The owner region stores authoritative cart state plus a bounded mutation log for handoff catch-up.

## Deep Dive: Split-Brain-Proof Ownership Handoff

The cart has exactly one writer at any time: the region that holds the current `(owner_region, epoch)` and the active `lease_id`.

### Data model (minimal)
- Directory row per user:
  - `owner_region`
  - `epoch` (monotonic integer)
  - `lease_id` (current owner’s lease)
  - `handoff_from_region` (nullable)
  - `handoff_barrier_seq` (nullable)
  - `handoff_token` (nullable)
  - `handoff_state`: `NONE | TRANSFERRING`
- Owner region per cart:
  - `cart_state`
  - `cart_seq` (monotonic)
  - `mutations(user_id, cart_seq, idempotency_key, mutation_payload)`
  - `handoff_frozen_epoch` (nullable)

### Write path (normal)
1. Edge routes mutation to `owner_region` and includes `epoch` + `idempotency_key`.
2. Owner Cart Service verifies it holds the active directory lease for `epoch`.
3. Owner Cart Service applies the mutation in a DB transaction:
   - dedupe by `idempotency_key`
   - increment `cart_seq`
   - persist updated `cart_state`
   - append to `mutations` with `cart_seq`

### Handoff trigger (user appears in new region)

**Step 1: Freeze the old owner and mint a barrier**
- Edge calls Region A: `PrepareHandoff(user_id, target=RegionB, epoch=current_epoch)`.
- Region A atomically:
  - verifies it is owner for `epoch`
  - sets `handoff_frozen_epoch = epoch` (rejects any further writes for that epoch)
  - returns `handoff_barrier_seq = current cart_seq` and `handoff_token` (random)

**Step 2: Atomically move ownership + fence**
- Edge updates the Directory with a compare-and-swap on expected `(owner_region=RegionA, epoch, handoff_state=NONE)`:
  - `epoch = epoch + 1`
  - `owner_region = RegionB`
  - `lease_id = new lease for RegionB` (and revoke A’s lease)
  - `handoff_from_region = RegionA`
  - `handoff_barrier_seq = value from Step 1`
  - `handoff_token = value from Step 1`
  - `handoff_state = TRANSFERRING`

**Step 3: New owner catches up to the barrier**
- Region B pulls from Region A: “give me all mutations up to `handoff_barrier_seq` for `handoff_token`”.
- Region B applies them locally, ending exactly at that sequence.

**Step 4: Complete handoff**
- Region B updates the Directory with a compare-and-swap on expected `(epoch, handoff_token, handoff_state=TRANSFERRING)`:
  - `handoff_state = NONE`
  - clears `handoff_from_region`, `handoff_barrier_seq`, `handoff_token`

**Acceptance rule:** Region B accepts writes for `(user_id, epoch=new)` only when `handoff_state=NONE`.

### Why this works
- Split brain is prevented by a single monotonic epoch and a single active owner lease in a linearizable directory.
- Lost updates are prevented by Step 1: the old owner freezes before the directory can move ownership.
- The protocol avoids global consensus on cart contents; it only requires it for ownership metadata.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Correctness under split brain | First write after travel is slower |
| Regional low-latency steady state | Added protocol complexity (handoff + leases) |
| Fewer moving parts | Non-owner reads are higher latency |
| Small global consistency surface | A global dependency (Directory) |

## Failure Modes

- **Directory unavailable**
  - Happens: leases cannot be renewed; ownership changes stall.
  - Detect: elevated directory RPC errors; lease renewal failures.
  - Recover: owners fail writes closed when the lease expires; reads continue via the last known owner in the session token; restore directory quorum.

- **Owner region outage during handoff**
  - Happens: directory shows `TRANSFERRING` and Region B cannot fetch mutations up to the barrier.
  - Detect: elevated `handoff_state=TRANSFERRING`, `handoff_duration_p99`.
  - Recover: keep writes rejected until Region A returns; after a fixed timeout, Region B takes ownership (epoch++) and starts from an empty cart (explicitly visible to the user).

- **Network partition: old owner can’t reach Directory**
  - Happens: Region A cannot renew its lease; it stops accepting writes when the lease expires.
  - Detect: lease renewal failures; spike in `409 NotOwner`.
  - Recover: clients refresh session token and route to the current owner.

- **Concurrent handoffs / flapping routing**
  - Happens: multiple handoffs race.
  - Detect: increased directory CAS conflicts; elevated `handoff_attempts`.
  - Recover: directory CAS on expected `(epoch, handoff_state)` ensures only one handoff wins; others retry after refresh.

## What We Removed

- Cross-region replication log (Kafka) and replicated read models in non-owner regions.
- Ownership “periodic refresh”; ownership is enforced by directory leases.
- Best-effort handoff; Step 1 freezes writes and Step 2 is a directory CAS, so no post-barrier writes can slip through.
- A background janitor that tries to “fix” stuck handoffs; resolution is deterministic timeout takeover.

## Operational Notes

- Alert on `epoch_mismatch_rate`, `lease_renewal_failures`, `handoff_duration_p99`, and `handoff_stuck_count`.
- Keep the client cart session token short-lived and refresh on any `409` response.
- Expose a “cart truth” debug endpoint that returns: directory ownership + lease, owner `cart_seq`, and last mutation IDs.
```
