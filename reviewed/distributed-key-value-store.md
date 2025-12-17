---
title: "Distributed Key-Value Store (Dynamo-Style)"
category: "Storage & Data Platforms"
difficulty: "Hard"
tags: ["distributed-systems", "key-value-store", "consistency"]
---

## Overview

A Dynamo-style distributed key-value store prioritizes **high availability** and **horizontal scalability** under node failures and network partitions. It does this by relaxing strong consistency: replicas can temporarily diverge, and reads may return multiple concurrent versions that must be reconciled.

The core idea is **tunable consistency per operation** using quorums:
- `N`: replication factor (how many replicas store a key)
- `W`: write quorum (acks required to accept a write)
- `R`: read quorum (responses required to answer a read)

When `R + W > N` *and* the system is not using “sloppy quorums” for that operation, reads and writes overlap on at least one replica, improving the chance of reading the latest value. This still does **not** guarantee linearizability (global single-copy behavior); instead it provides a practical, latency-friendly model often described as **quorum consistency** for single-key operations.

To handle divergence, the system treats conflicts as first-class:
- Detect causality with **vector clocks** (preferred) and return siblings when updates are concurrent.
- Optionally use **Last-Write-Wins (LWW)** for simpler applications, ideally with **Hybrid Logical Clocks (HLC)** to reduce clock-skew issues.
- Converge replicas via **read repair** (on reads) and **anti-entropy repair** (background reconciliation, typically Merkle-tree-based).

## Requirements

### Functional Requirements
- `Put/Get/Delete` by key with opaque byte values.
- Per-request tunable consistency using `N`, `R`, `W`, plus sane presets (`ONE`, `QUORUM`, `ALL`).
- Partitioning via consistent hashing; automatic node add/remove with rebalancing.
- Replication across failure domains (rack/AZ-aware placement).
- Conflict detection and surfacing multiple versions (siblings); application-assisted resolution when needed.
- Conditional writes/deletes using client-provided version context (compare-and-set semantics).
- Hinted handoff for short outages; read repair and background anti-entropy repair.
- Operational APIs and tooling: health, membership, stats, repair controls, drains, and safe rebalancing.

### Non-Functional Requirements (Targets)
**Canonical capacity scenario (single region):**
- **Cluster size**: ~500 nodes across 3 AZs (rack/AZ-aware placement).
- **Data**: 200 TB *logical* user data.
- **Replication**: `N=3` ⇒ ~600 TB *physical* before overhead.
- **Storage overhead**: +25% (tombstones, version metadata, compaction, indexes) ⇒ ~750 TB physical.
- **Node storage**: 2 TB usable per node ⇒ ~1,000 TB total capacity ⇒ ~25% headroom.

**Traffic (steady state, in-region):**
- **Reads**: 300k QPS average, 1.5M QPS peak (hot events).
- **Writes**: 150k QPS average, 500k QPS peak.
- **Value sizes**: median 512 B–2 KB; P99 ≤ 64 KB; hard limit 1 MB (larger values should go to object storage).

**Latency SLOs (in-region):**
- `GET` (small values):
  - `R=1`: P50 3–8 ms, P99 30–60 ms
  - `R=2` (cross-AZ): P50 6–15 ms, P99 50–120 ms
- `PUT` (durable mode, WAL fsync with group commit):
  - `W=2`: P50 8–20 ms, P99 60–150 ms  
  (If `fsync` is required per write with no batching, tail latency will be higher.)

**Availability target:**
- 99.99% monthly successful operations for `ONE/QUORUM` in steady state.
- Degrade gracefully under partitions (may return conflicts; may fail `ALL` and strict quorums).

**Durability target:**
- An acknowledged write is persisted to at least `W` replicas’ WAL.
- Data loss requires correlated failures beyond the durability envelope (e.g., multiple replica disks + lack of backups).

### Consistency Model (What Callers Get)
- **Default**: eventual consistency with conflict surfacing.
- **Read-your-writes**: achievable *per session* when clients (a) route consistently (sticky coordinator or token-aware routing), (b) include version context, and (c) avoid sloppy quorum for those operations.
- **No multi-key transactions**; no global ordering across keys.
- **Monotonic reads / writes**: can be approximated with client context and session policies, not guaranteed universally under partitions.

### Constraints & Assumptions
- Single-region is the base design; cross-region replication is async and optional.
- Multi-tenant internal service (quotas, authn/z, auditability).
- Security: mTLS node-to-node, authn/z for clients, encryption at rest, optional per-tenant keys (KMS).
- This system is optimized for point lookups, not scans/range queries.

## Architecture

```mermaid
flowchart LR
  C[Client] --> LB[Client-side routing / LB]
  LB --> N1[Node (Coordinator + Replica)]
  LB --> N2[Node (Coordinator + Replica)]
  LB --> N3[Node (Coordinator + Replica)]

  subgraph Cluster["Cluster (gossip membership + ring state)"]
    N1 --- M[Membership + Ring Metadata]
    N2 --- M
    N3 --- M

    N1 -->|replicate| N2
    N1 -->|replicate| N3
    N2 -->|replicate| N3

    N1 --> S1[(Local LSM Store)]
    N2 --> S2[(Local LSM Store)]
    N3 --> S3[(Local LSM Store)]

    N1 <--> R[Repair Subsystem\n(read repair + anti-entropy)]
    N2 <--> R
    N3 <--> R

    N1 --> H[Hints Queue]
    N2 --> H
    N3 --> H
  end
```

**Key architectural choices**
- **Any node can be a coordinator**: clients can connect to any healthy node; the coordinator routes requests to the key’s replica set.
- **Consistent hashing + vnodes**: spreads ownership evenly and reduces rebalancing pain when nodes join/leave.
- **Rack/AZ-aware replica placement**: prevents all replicas landing in one failure domain.
- **Two convergence paths**:
  - **Read repair**: fixes stale replicas discovered during reads.
  - **Anti-entropy**: continuously reconciles partitions/missed writes without full scans.

### Write Path (with hints)
```mermaid
flowchart TD
  A[Client PUT key,value] --> B[Coordinator computes preference list]
  B --> C{Send to N replicas}
  C -->|acks| D[Wait for W acks]
  C -->|unreachable replica| E[Pick next replica (sloppy quorum) + store hint]
  D --> F[Return success]
  E --> F
  E --> G[Hint replay when target returns]
```

### Read Path (digest + repair)
```mermaid
flowchart TD
  A[Client GET key] --> B[Coordinator queries replicas in parallel]
  B --> C[One full value + (N-1) digests optional]
  C --> D{Have R responses?}
  D -->|yes| E[Merge versions by causality]
  E --> F{Conflicts?}
  F -->|no| G[Return single version]
  F -->|yes| H[Return siblings + contexts]
  E --> I[Async read repair to stale replicas]
```

## Components

### Coordinator (Request Router)
**Responsibilities**
- Compute replica preference list for a key.
- Execute reads/writes with quorum logic, deadlines, retries, and hedging policies.
- Merge read responses (causal comparison) and trigger read repair.
- Enforce per-tenant quotas, payload limits, and authz checks.

**Key details**
- Uses per-request timeouts and cancels slow replica RPCs once quorum is reached (to limit tail amplification).
- For reads, can use a **digest read** optimization: fetch full value from one replica and hashes from others; fetch full values only if digests disagree.

### Membership & Ring
**Responsibilities**
- Track node liveness and disseminate membership state.
- Maintain ring/token ownership with a deterministic mapping from key → vnode → replica set.

**Typical approach**
- **SWIM-style gossip** for liveness with bounded fanout (scales well).
- A ring state version (epoch) to converge configuration changes.
- Optional “operator-controlled” changes (e.g., via a small control plane) to avoid accidental mass reshuffles.

**Replica placement**
- Preference list picks replicas across distinct AZs/racks when possible.
- If the cluster is imbalanced, placement should degrade gracefully but emit alerts.

### Replica Storage Engine
**Responsibilities**
- Persist versions and tombstones, serve reads, apply writes, compact data, provide iterators for repair.

**Technology**
- Embedded LSM (e.g., RocksDB/Pebble) with WAL, compression, checksums, and tuned compaction.
- Separate column families (or key prefixes) for:
  - `data`: versioned values
  - `index`: key → current version ids (bounded)
  - `tombstone`: delete markers with GC metadata
  - `hints`: hinted handoff payloads (often better stored separately from main DB)

### Replication & Quorum Semantics
**Write (`N`,`W`)**
- Coordinator sends to the `N` preferred replicas.
- Success when `W` replicas durably persist (WAL append + group commit).
- Remaining replicas are best-effort; background repair ensures convergence.

**Read (`N`,`R`)**
- Coordinator queries replicas in parallel.
- Returns after `R` responses (or earlier if using “fast read” policy), then optionally continues in background for repair signals.

**Sloppy quorum**
- If a preferred replica is down, coordinator may write to a fallback node to preserve availability, recording a **hint** for later replay.
- Important implication: sloppy quorum improves availability but weakens the practical guarantee implied by `R + W > N` during failures.

### Conflict Detection & Resolution
**Preferred: vector clocks**
- Each stored version has a vector clock describing its causal history.
- On `Put`, client includes context (vector clock) from a previous read; coordinator:
  1. Merges provided clocks (take per-node max),
  2. Increments its own entry (or a logical writer ID),
  3. Writes a new version.
- On `Get`, coordinator returns:
  - a single “winner” if one version dominates others causally, or
  - multiple siblings if versions are concurrent.

**Optional: LWW (with HLC)**
- Choose the version with the greatest `(hlc_timestamp, node_id)` to break ties.
- Easier for callers, but can silently drop concurrent updates.

**Operational safeguards**
- Bound sibling count (e.g., max 10). If exceeded, require application resolution or enforce an LWW fallback with alarms.
- Periodic sibling GC when causal dominance is established.

### Repair Subsystem (Convergence)
- **Read repair**: when a read observes divergence, asynchronously update stale replicas with the winning version set.
- **Anti-entropy repair**: per-vnode background reconciliation using **Merkle trees** (or range-hash summaries) to locate differing key ranges efficiently.
- **Throttling**: repair must be rate-limited by CPU, IO, and network budgets to protect foreground latency.

## Data Model

### Logical Record (per stored version)
- `key: bytes`
- `value: bytes` (or empty for tombstone marker)
- `version_id: bytes` (unique identifier for this version)
- `vclock: map<writer_id,uint64>` (or `hlc_ts` in LWW mode)
- `last_modified_ms: int64` (observability; not authoritative for ordering in vclock mode)
- `expires_at_ms: int64?` (TTL)
- `is_tombstone: bool`

### Physical Layout (typical LSM-friendly keys)
- `data_cf`: `(key || version_id) -> value + version_metadata`
- `index_cf`: `key -> [version_id...]` (bounded list of live siblings, ordered by causality/recency)
- `tombstone_cf`: `key -> tombstone_metadata` (or treat tombstones as versions in `data_cf`)
- Optional: `hint_cf` or separate local log store for hinted handoff payloads

### Deletes, Tombstones, and “Resurrection”
Deletes are implemented as tombstones to prevent deleted data from reappearing due to late repair.
- Tombstones replicate like writes and participate in conflict resolution.
- Tombstones have a **GC grace** (e.g., 7–30 days) after which they may be purged, assuming repair has had time to propagate the delete.
- Anti-entropy must treat tombstones as first-class; otherwise deleted keys can resurrect.

## API Design

Protocol: gRPC (recommended); optional REST gateway for simple clients.

### Core RPCs
- `Put`: store a value with optional conditional context.
- `Get`: fetch value(s) and context for subsequent conditional writes.
- `Delete`: write a tombstone, optionally conditional.

#### gRPC sketch (illustrative)
```proto
service Kv {
  rpc Put(PutRequest) returns (PutResponse);
  rpc Get(GetRequest) returns (GetResponse);
  rpc Delete(DeleteRequest) returns (DeleteResponse);
}

message Quorum {
  uint32 n = 1;
  uint32 r = 2;
  uint32 w = 3;
}

message VersionContext {
  bytes vclock = 1; // opaque to clients, returned by Get
}

message PutRequest {
  bytes key = 1;
  bytes value = 2;
  Quorum quorum = 3;
  VersionContext if_match = 4; // optional CAS-like precondition
  uint32 ttl_seconds = 5;      // optional
  string idempotency_key = 6;  // optional
}

message PutResponse {
  VersionContext context = 1;
  uint32 replica_acks = 2;
}

message GetRequest {
  bytes key = 1;
  Quorum quorum = 2;
  bool return_conflicts = 3;
}

message ValueVersion {
  bytes value = 1;
  VersionContext context = 2;
  int64 last_modified_ms = 3;
}

message GetResponse {
  repeated ValueVersion versions = 1; // 1 if resolved, >1 if conflicting
  bool resolved = 2;
}

message DeleteRequest {
  bytes key = 1;
  Quorum quorum = 2;
  VersionContext if_match = 3; // optional
}

message DeleteResponse {
  VersionContext context = 1;
  uint32 replica_acks = 2;
}
```

### Error Handling (examples)
- `INVALID_ARGUMENT`: invalid quorum (`w > n`, etc.), size limits.
- `FAILED_PRECONDITION`: conditional context mismatch (CAS failure).
- `UNAVAILABLE`: could not reach required quorum within deadline.
- `DEADLINE_EXCEEDED`: coordinator timed out waiting for quorum.

### Idempotency
If `idempotency_key` is provided, coordinators keep a short-lived cache of outcomes keyed by `(tenant_id, client_id, idempotency_key)` to safely retry on timeouts without duplicating side effects.

## Scaling & Performance

### Capacity Planning Notes
- **Replicated write amplification**: each logical write becomes `N` replica writes plus compaction overhead.
- **Foreground vs repair IO**: repair traffic must be budgeted; otherwise tail latency and compaction stalls spike.
- **Hot keys**: a single key can bottleneck a quorum read/write; per-key rate limits and caching become essential.

### Bottlenecks & Mitigations
- **Hot keys / skew**
  - Mitigate with client-side key salting (if acceptable), coordinator caching, and per-key rate limiting.
  - Consider “hedged reads” for tail latency, but cap concurrency to avoid load storms.
- **LSM compaction pressure**
  - Separate WAL/DB devices when possible, tune compaction, compression, and memtables.
  - Monitor write stalls and compaction debt; add nodes before sustained debt accumulates.
- **Coordinator fanout and tail latency**
  - Parallel RPCs with strict deadlines; cancel in-flight calls after quorum.
  - Prefer digest reads to reduce bytes transferred on high-QPS workloads.
- **Repair competing with foreground**
  - Rate limit, schedule by priority (recent partitions first), and pause repair during incidents.

### Horizontal Scaling & Rebalancing
- Use many vnodes (e.g., thousands cluster-wide) so ownership can move in small increments.
- Node join triggers streaming of vnode ranges to the new owner; throttle streaming to avoid saturating disks.
- Draining a node (planned removal) transfers ownership first, then removes it from the ring.

### Caching Strategy
- **Replica-local cache**: RocksDB block cache and OS page cache for hot SST blocks.
- **Coordinator cache (optional)**: small TTL (100 ms–1 s) for extreme read hotspots; correctness relies on TTL and quorum policy.
- **Negative caching**: short TTL (50–200 ms) for `NOT_FOUND`, with caution under eventual consistency and deletes.

## Trade-offs & Alternatives

### Key Trade-offs
- **Eventual consistency + tunable quorums**
  - Pros: high availability under partitions, low latency, simple horizontal scale.
  - Cons: conflicts, weaker semantics under sloppy quorum, more complex client behavior.
- **Vector clocks (conflict detection)**
  - Pros: distinguishes causality vs concurrency; avoids silent lost updates.
  - Cons: metadata overhead, sibling management, client context required for best results.
- **LSM-based local storage**
  - Pros: strong write throughput, mature tooling.
  - Cons: compaction cost, tail latency under IO pressure, operational tuning required.

### Alternatives
- **Strong consistency via Raft per shard**
  - Better semantics (linearizable reads/writes), simpler client model.
  - Higher write latency, reduced availability during partitions, operational complexity at very high scale.
- **Primary-backup per shard**
  - Simpler than Raft, decent performance.
  - Failover complexity and single-writer bottlenecks; weaker availability.
- **CRDT-based values**
  - Great for specific mergeable data types (counters, sets).
  - Not general-purpose; pushes complexity into application data modeling.

## Failure Modes & Mitigations

### Failure Scenarios
1. **Single replica node down**
   - Impact: reduced capacity; `ALL` may fail; `QUORUM` may succeed if enough replicas remain.
   - Mitigation: hinted handoff, fallback to sloppy quorum (if allowed), accelerated repair on recovery.

2. **AZ outage**
   - Impact: one replica per key may be unavailable (with AZ-aware `N=3`); `QUORUM` can still succeed across remaining AZs.
   - Mitigation: enforce cross-AZ placement; ensure clients can reach multiple AZ endpoints; pre-provision capacity headroom.

3. **Network partition (split-brain)**
   - Impact: concurrent writes accepted on different sides; conflicts on healing.
   - Mitigation: vector clocks + anti-entropy; surface siblings; prioritize repair; alert on conflict rate.

4. **Coordinator overload / cascading retries**
   - Impact: cluster-wide tail latency spikes, quorum failures due to timeouts.
   - Mitigation: load shedding, per-tenant rate limits, bounded retries with jitter, circuit breakers, hedging caps.

5. **Disk full / compaction stall**
   - Impact: write stalls, timeouts, node instability.
   - Mitigation: enforce quotas, proactive compaction debt alerts, TTL cleanup, add capacity, throttle repair/streaming.

6. **Hint queue growth (long outage)**
   - Impact: storage pressure; replay storms when node returns.
   - Mitigation: cap hint retention, spill to separate storage, replay with strict rate limits, fall back to full repair if hints expire.

7. **Clock issues (LWW mode)**
   - Impact: wrong winner selection and lost update semantics.
   - Mitigation: prefer vector clocks; if LWW, use HLC + monitor skew; alarm on time drift.

### Disaster Recovery (DR)
- **Backups**: periodic SST snapshots + WAL archiving to object storage; integrity checks and continuous restore testing.
- **RPO/RTO (example targets)**: RPO 5–15 minutes (async), RTO 30–60 minutes (region rebuild and restore).
- **Regional failover (optional)**: async replication or dual-write at application level; client traffic steering via DNS/traffic manager.

## Operations

### Monitoring (SLIs) and Alerting
**Core SLIs**
- Availability: success rate by operation (`Put/Get/Delete`) and by consistency level.
- Latency: P50/P95/P99 per op; tail amplification (coordinator fanout time).
- Consistency signals: sibling/conflict rate, stale-read indicators (digest mismatches).
- Quorum health: insufficient acks, timeout rates, unreachable replicas.
- Repair health: repair lag per vnode, bytes repaired, divergence rate.
- Hints: queue depth, oldest hint age, replay throughput.
- Storage: disk usage, compaction backlog, write stalls, block cache hit rate, WAL sync time.
- Resources: CPU, RSS, FD usage, network saturation.

**Example alerts**
- P99 `Get` or `Put` > SLO for 5–10 minutes.
- Quorum failure rate > 0.5–1% for 5 minutes (by tenant and cluster-wide).
- Disk > 85% or compaction stalls detected.
- Oldest hint age > 10 minutes (or your operational SLA).
- Repair lag > 24 hours for any vnode (or increasing trend).

### Deployment & Upgrades
- Rolling deploy with `max_unavailable` (e.g., 2–5%) while preserving `QUORUM` availability.
- Backward/forward compatibility for:
  - gossip/membership protocol
  - on-disk schema and metadata
  - repair formats
- Canary + bake time; monitor conflict and quorum failure rate during rollout.
- Safe rollback: binary rollback; gate new on-disk features behind flags with staged migrations.

### Security & Multi-Tenancy
- mTLS for node-to-node and client-to-cluster.
- Authn/z per tenant; quotas (QPS, storage, max value size).
- Encryption at rest; optional per-tenant keys via KMS.
- Audit logs for admin actions and sensitive operations.

### Operational Playbooks (minimum set)
- Node replacement (disk failure), safe drain, and rejoin procedures.
- Hot partition / hot key handling (rate limits, caching, mitigation guidance to clients).
- Repair backlogs (throttle tuning, prioritization, incident-mode settings).
- Compaction stall response (pause repairs/streaming, expand capacity, tune compaction).
- Data restore and validation workflow (periodic game days).

## References & Further Reading
- Dynamo: https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Riak (Dynamo-inspired KV): https://riak.com/
- Cassandra architecture (Dynamo + Bigtable ideas): https://cassandra.apache.org/doc/latest/
- Vector clocks: https://en.wikipedia.org/wiki/Vector_clock
- Merkle trees: https://en.wikipedia.org/wiki/Merkle_tree
- SWIM membership: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf