```markdown
---
title: "Distributed Key-Value Store (Dynamo-Style)"
category: "Storage & Data Platforms"
difficulty: "Hard"
tags: [dynamo, kv-store, quorum, eventual-consistency, consistent-hashing, vector-clocks, lww]
---

## Overview

This system is a Dynamo-style distributed key-value store optimized for high availability and predictable latency under partial failure. It shards keys via consistent hashing, replicates each key to `N` nodes, and lets callers tune consistency per operation with quorum reads/writes (`R`, `W`) rather than baking in a single consistency model.

The key insight is to treat *coordination as a per-request behavior, not a fixed leader*: any node can coordinate a read/write using membership data, and correctness comes from (1) quorum intersection when you want it and (2) disciplined conflict handling when you don’t. Everything else stays boring: local LSM storage (RocksDB), gossip membership (SWIM), background repair (Merkle trees), and bounded “make progress anyway” mechanisms (sloppy quorum + hinted handoff).

## What Makes This Hard

Naive implementations underestimate three things:

1. **Metadata growth and conflict semantics**: vector clocks can explode if you attach identity to “writers” incorrectly, and LWW can silently lose updates if you lean on wall clocks.
2. **Keeping the system “available” without letting entropy win**: sloppy quorum and hinted handoff keep writes flowing during failures, but without aggressive anti-entropy you end up with permanent divergence and strange read behavior.
3. **Operational safety of deletes and repairs**: tombstones, compaction, and repair jobs interact; get this wrong and you oscillate between resurrected data and disk blowups.

## Requirements

### Functional Requirements
- `GET(key)`, `PUT(key, value)`, `DELETE(key)` with per-request consistency: choose `R`/`W` (or presets like `ONE`, `QUORUM`, `ALL`).
- Conflict resolution modes per-namespace:
  - **Vector-clock**: detect concurrent versions and return siblings to the client (or a server-side merge function).
  - **LWW**: pick a single winner deterministically using Hybrid Logical Clocks (HLC), not raw wall time.
- Always-on writes during replica loss via **sloppy quorum**, with eventual convergence via **hinted handoff + anti-entropy**.
- Bounded staleness mechanisms: **read repair** on quorum reads, plus scheduled background repair.
- Multi-tenant safety: per-namespace quotas and limits (value size, sibling cap, hint cap).

### Scale Targets
- **Cluster size**: 50–200 nodes (failure is normal at this size; design must assume constant churn).
- **Data**: 50 TB logical, ~150 TB physical at `N=3` (capacity planning revolves around replication overhead + compaction).
- **Throughput**: 100k writes/s, 300k reads/s sustained (forces careful coordination path: no global leader, minimal cross-node chatter).
- **Latency**: p99 `GET` < 20 ms, p99 `PUT` < 30 ms within a region (makes tail latency under partial failure the real constraint, not average throughput).

## Key Design Decisions

- **Tunable consistency via quorums (`R`,`W`) on `N` replicas**
  - Chose: quorum reads/writes with coordinator-per-request.
  - Rejected: single-leader replication (too fragile for tail latency and availability under partitions).
  - Why: quorums give *a dial*, not a binary choice; `R+W>N` yields strong-ish read-your-writes, while `R=1/W=1` buys availability.

- **Partitioning with consistent hashing + virtual nodes**
  - Chose: ring with vnodes (e.g., 256 vnodes/node), replication to the next `N` distinct nodes.
  - Rejected: range sharding (hotspot-prone, painful splits) and centralized partition map (becomes an availability dependency).
  - Why: vnodes smooth skew and make rebalancing “move many small things” instead of “move a few terrifying things”.

- **Conflict handling as a first-class API choice (Vector Clocks vs LWW/HLC)**
  - Chose: per-namespace mode: vector clocks (sibling-aware) for correctness-sensitive data; LWW with HLC for simplicity-sensitive data.
  - Rejected: pretending conflicts don’t exist (you end up with phantom data loss).
  - Why: the store can’t guess whether overwriting is safe; forcing an explicit mode prevents accidental semantics.

## Architecture

```mermaid
flowchart LR
  C[Client SDK] --> LB[Request Router]
  LB --> N1[Any Node<br/>Coordinator]

  subgraph R["Replica Set (N)"]
    A[Replica Node A]
    B[Replica Node B]
    D[Replica Node C]
  end

  N1 --> A
  N1 --> B
  N1 --> D

  N1 <--> G[Gossip (SWIM)]
  A <--> AE[Anti-Entropy<br/>(Merkle Repair)]
  B <--> AE
  D <--> AE
  N1 --> O[Observability]
  A --> O
  B --> O
  D --> O
```

### Components

- **Client SDK**
  - Encodes consistency level (`R`,`W`) and namespace conflict mode expectations.
  - Retries safely with idempotency tokens for `PUT/DELETE` (prevents “double write” amplification on timeouts).

- **Request Router**
  - Simple L7 routing to any healthy node; no “smart” partition routing needed because any node can coordinate.

- **Coordinator (Any Node)**
  - Computes the key’s vnode/token, picks the preference list (replicas), executes quorum logic, and returns either a single value (LWW) or siblings (vector-clock mode).
  - Owns hedged requests and timeouts to control tail latency.

- **Replica Nodes**
  - Store data locally in **RocksDB** (LSM), keyed by `(partition, key)` with version metadata.
  - Maintain per-partition Merkle trees / segment hashes to support efficient divergence detection.

- **Gossip (SWIM)**
  - Membership + failure suspicion used to build the ring and preference lists without a coordinator service.
  - Drives “distinct node” selection for replicas (avoid putting multiple replicas on the same failed rack/host class).

- **Anti-Entropy (Merkle Repair)**
  - Periodically compares partition trees between replicas, pulls missing versions/tombstones, and converges the replica set.
  - The system stays correct because *repair is guaranteed*, not because failure is rare.

- **Observability**
  - Critical signals: hint backlog, sibling rate, repair lag, read-repair rate, compaction debt, and coordinator timeout rates.

## Deep Dive: Sloppy Quorums + Conflict Resolution (The Real Dynamo Trick)

A write is a race between *availability* and *agreement*. Dynamo’s answer is: **never block the write on perfect placement**, but always preserve enough information to reconcile later.

### Write Path (PUT/DELETE)

1. **Coordinator selects replicas**: compute the vnode, take the next `N` distinct nodes as the preference list.
2. **Send writes in parallel** to those `N`. Each replica stores:
   - The value (or tombstone).
   - Version metadata:
     - **Vector-clock mode**: coordinator increments its `(node_id, counter)` entry and attaches the vector clock.
     - **LWW mode**: coordinator stamps with **HLC** `(physical_time, logical_counter, coordinator_id)` to provide monotonicity without trusting wall clocks.
3. **Wait for `W` acknowledgements**.
4. If not enough replicas respond, **sloppy quorum** kicks in:
   - Coordinator continues down the preference list to healthy nodes and writes “on behalf of” the intended replica set.
   - These off-target writes are stored as **hints** with a strict cap (bytes + age). If the cap is hit, the write fails fast; unbounded hints are a slow-motion outage.

This design is opinionated about one subtlety: **vector clocks are per-object and per-replica/coordinator identity, not per-client identity**. If you tie clock entries to “clients”, the clock becomes unbounded in any multi-writer scenario. Replica/coordinator IDs are bounded by cluster size, and you can prune dominated entries once repair converges.

### Read Path (GET)

1. Coordinator queries the preference list in parallel.
2. **Wait for `R` responses**, then:
   - **LWW mode**: pick the max HLC version; if older versions appear, issue **read repair** to lagging replicas (in the background, never on the critical path).
   - **Vector-clock mode**: compute partial order:
     - If one version’s clock dominates all others, return it.
     - If there are concurrent versions, return **siblings** (bounded to a max; if exceeded, fail the read with a “too many siblings” error to force a domain decision).
3. If `R=1`, staleness is expected; the system compensates with background repair, not wishful thinking.

### Why Anti-Entropy Is Non-Negotiable

Sloppy quorum and hints keep the system writable during failures, but they *manufacture divergence*. Merkle-tree repair is what turns “we wrote somewhere” into “we wrote correctly” after the network heals. Without it, you get the worst of both worlds: availability during incidents and data inconsistency forever.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| High availability under partitions | Immediate global consistency |
| Predictable p99 latency (parallelism + hedging) | Higher write amplification (replication + repair) |
| Operational simplicity (no leader service) | More background work (repair, compaction, tombstones) |
| Explicit conflict semantics (vector clocks / LWW) | More complexity at API boundary |

## Failure Modes

- **Network partition splits the replica set**
  - What happens: writes succeed via sloppy quorum; reads may return stale values or siblings.
  - Detect: elevated coordinator timeouts, mismatch between membership views, rising hint backlog.
  - Recover: membership stabilizes; hinted handoff drains; anti-entropy repairs partitions until divergence metrics return to baseline.

- **Hint backlog grows without bound (slow-motion outage)**
  - What happens: disk fills, compaction debt spikes, read latency degrades, then cascading failures.
  - Detect: hint bytes/age crossing SLO, compaction pending bytes, replica write stalls.
  - Recover: enforce hard caps + shedding (fail writes rather than hoarding); prioritize handoff and repair; temporarily raise `W` only if you can afford reduced availability.

- **Deletes resurrect (tombstone mishandling)**
  - What happens: a replica that missed a tombstone later “wins” during repair or LWW.
  - Detect: resurrection counters, tombstone/put inversion alerts in repair logs.
  - Recover: treat tombstones as first-class versions that replicate and repair; keep tombstones for `T_gc` > maximum repair interval; never drop tombstones before repair convergence.

## What I'd Do Differently At...

- **10x scale:**
  - Add rack/zone-aware replica placement and admission control tied to compaction debt.
  - Split “coordinator” and “storage” roles on the same node with isolation (CPU and IO budgets) to protect tail latency.

- **100x scale:**
  - Move from per-partition Merkle trees to more incremental, streaming repair metadata (Merkle rebuild costs become painful).
  - Introduce multi-region replication as a separate layer (async log shipping per partition); trying to stretch Dynamo semantics across WAN without a dedicated replication strategy becomes operationally brutal.

## Operational Notes

- `R/W` defaults matter more than features: pick sane presets (`QUORUM` for most reads, `ONE` for latency-sensitive caches, `ALL` only for maintenance).
- Watch **sibling rate** like an error budget: rising siblings means either too-low `R/W` for the workload or a repair system falling behind.
- Set `T_gc` (tombstone retention) based on worst-case repair + outage windows; a short `T_gc` is the fastest path to resurrection bugs.
- Compaction debt is your hidden incident precursor; throttle writes before the LSM falls over.
- Repair must be schedulable, observable, and bounded; “best effort” repair turns into permanent inconsistency at scale.
```