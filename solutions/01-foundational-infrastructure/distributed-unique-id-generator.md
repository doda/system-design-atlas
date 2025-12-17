---
generation_time_seconds: 1037
title: "Distributed Unique ID Generator"
category: "Foundational Infrastructure"
difficulty: "Medium"
tags: ["ids", "snowflake", "time", "multi-region", "reliability"]
---

## Overview

This system issues 64-bit, time-sortable unique identifiers at very high QPS, across multiple regions, without any cross-region dependency on the request path.

Each generator keeps the hot path local: a timestamp plus a per-millisecond counter. “Time” is treated as a constrained input: a Hybrid Logical Clock (HLC) rule makes IDs strictly increasing per generator, and a hard skew fence forces the node to stop rather than mint IDs from a provably unsafe clock.

## What Makes This Hard

Clocks jump. A restart plus a backward clock step can re-emit an old `(timestamp, counter)` and create real collisions unless you fence restarts.

Multi-region adds another trap: you can have time-sortable IDs without promising a global total order. The contract must be explicit.

## Requirements

### Functional Requirements
- Return a 64-bit unique ID per request.
- IDs are **time-sortable**: sorting by ID yields creation-time order *except within a bounded skew window*.
- Strong protection against backward clock jumps: never emit IDs that go “back in time” on the same generator; never emit duplicates across restarts.
- Multi-region active-active: any region can serve IDs independently; regional failure does not stop issuance globally.
- Operators can detect and contain bad time sources quickly.

### Scale Targets
- **1M IDs/sec per region** sustained (hot path must be CPU-cache fast; coordination must be off-path).
- **P99 < 2 ms** within-region for the ID API (single network hop + local generation).
- **Availability 99.99%** per region (ID generation is a dependency that blocks writes everywhere).
- **Up to 32 regions**, **up to 1024 generator nodes per region** (enough headroom for expansion and isolating noisy neighbors).

## Key Design Decisions

- **Decision 1: Signed-safe, Snowflake-shaped 64-bit ID**
  - Chose: `0 | timestamp_ms | region_id | node_id | logical` (top bit is always `0` so numeric sorts work in signed systems).
  - Rejected: UUIDv4 (not sortable), ULID without skew fencing (still breaks on clock rollback), a global sequencer (becomes a multi-region choke point).
  - Why: time-sortable IDs enable efficient DB indexes/logs; reserving the sign bit avoids “ordering breaks in BIGINT” later.

- **Decision 2: One per-region control plane: Kubernetes `Lease` for restart fencing**
  - Chose: run generators as a Kubernetes `StatefulSet` (stable `node_id` = ordinal) and store a per-`node_id` high-water mark in a `Lease`.
  - Why: no extra coordination system; restart-safety becomes a single read/write to the API server off the hot path.

- **Decision 3: HLC + skew fence (fail safe, not “best effort”)**
  - Chose: HLC rule on each generator: never decrease the timestamp field; use logical bits when time stalls.
  - Rejected: “just wait for NTP” without hard limits (silent correctness loss), “always bump time” without alerting (hides real incidents).
  - Why: correctness beats availability when the clock is provably unsafe; a quarantined ID node is cheaper than a corrupted global order.

## Architecture

```mermaid
flowchart TB
  C[Clients] --> DNS["DNS (multiple regional endpoints)"]
  DNS --> R1
  DNS --> R2

  subgraph R1["Region A"]
    A["ID Generator (StatefulSet)"]
    K1["Kubernetes API (Lease)"]
    A <--> K1
  end

  subgraph R2["Region B"]
    B["ID Generator (StatefulSet)"]
    K2["Kubernetes API (Lease)"]
    B <--> K2
  end

### Components

- `DNS (multiple regional endpoints)`: simplest global routing; clients retry another region on failure.
- `ID Generator (StatefulSet)`: serves the ID API; keeps `(last_ts_ms,last_logical)` in memory for the hot path.
- `Kubernetes Lease`: stores a per-`node_id` high-water mark so a restart cannot re-emit old IDs.
- `Metrics/Alerts`: export clock offset, skew-fence trips, lease write failures, and logical exhaustion to your existing metrics stack.

What we removed: per-region etcd/Consul, anycast L7 load balancing, and any dedicated “metrics service” beyond exporting metrics.

## Deep Dive: Clock Skew Protection and Ordering

**ID format (64-bit, big-endian comparable):**
- `sign` (1 bit): always `0` (keeps IDs non-negative for signed numeric sorts).
- `timestamp_ms` (40 bits): milliseconds since a fixed custom epoch (gives ~34 years).
- `region_id` (5 bits): up to 32 regions.
- `node_id` (10 bits): up to 1024 generators per region.
- `logical` (8 bits): per-ms counter / logical ticks (256 IDs per ms per node ≈ 256k IDs/sec/node).

**Generator state (per node):**
- `last_ts_ms`: last emitted timestamp_ms
- `last_logical`: last emitted logical value (0..255)

**Restart fence (off hot path):**
- For each `node_id`, store `hi_ts_ms` and `hi_logical` in a Kubernetes `Lease` for that ordinal.
- On startup, read the lease and initialize the in-memory state to *at least* that high-water mark:
  - set `(last_ts_ms,last_logical) = (hi_ts_ms, hi_logical)`; if `hi_logical == 255`, start at `(hi_ts_ms + 1, 0)` instead.
- Periodically (e.g., every 250 ms), update the lease with the current `(last_ts_ms,last_logical)`.
- If lease updates fail for longer than a short grace period, stop serving IDs (fail safe).

**HLC rule (hot path):**
1. Read `now_ms`.
2. Compute `ts = max(now_ms, last_ts_ms)`.
3. If `ts == last_ts_ms`, increment `logical`; if it overflows, block until `now_ms` advances (or return `429`).
4. If `ts > last_ts_ms`, set `logical = 0`.
5. Emit ID and atomically store `(last_ts_ms, last_logical)`.

This guarantees: **on a single generator node, IDs are strictly increasing**, even if the wall clock stalls or goes backward briefly.

**Skew fence (correctness over availability):**
- Define `MAX_BACKWARD_MS = 10`.
- If `now_ms < last_ts_ms - MAX_BACKWARD_MS`, the node enters **QUARANTINE**:
  - Stop serving IDs (return `503`).
  - Emit a high-severity alert including host, offset, and NTP status.
  - Recovery is “fix time and restart”.

Why this matters: without a hard fence, a badly skewed node can emit IDs that appear “in the past” relative to other systems, corrupting time-based sharding, ordering, and TTL logic.

**Multi-region ordering truth (be explicit):**
- This system guarantees **time-sortability**, not a global total order.
- Define `SKEW_BOUND_MS = 250`. If `tA + SKEW_BOUND_MS < tB`, then `id(A) < id(B)` holds.
- During region failover, IDs from different regions interleave; they remain sortable by their embedded timestamp, but not strictly monotonic across regions.

That’s the honest contract that keeps the design simple and reliable.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Hot-path speed (local generation) | Global total ordering across regions |
| Correctness under clock rollback (fail safe) | Availability of a single skewed node |
| Operational simplicity (one control plane) | Availability during Kubernetes API/control-plane incidents |
| Signed numeric sort safety | Timestamp horizon (~34 years from epoch) |

## Failure Modes

- **Clock steps backward on a node**
  - What happens: skew fence triggers; node stops issuing IDs.
  - Detection: alert on `clock_offset_ms`, `skew_fence_trips`, NTP daemon status.
  - Recovery: restart on a healthy host; capacity is recovered by other nodes.

- **Kubernetes API unavailable / partitioned from pods**
  - What happens: lease updates fail; after the grace period the pod stops serving IDs.
  - Detection: `lease_write_errors`, `lease_write_stall_ms`.
  - Recovery: restore control plane/network; pods resume once lease writes succeed.

- **Pod restarts with the same `node_id`**
  - What happens: pod reads the lease high-water mark and resumes above it; no duplicates.
  - Detection: log/metric `restart_fence_applied` with `(hi_ts_ms,hi_logical)`.
  - Recovery: none.

- **Sequence/logical exhaustion (too many IDs in one ms on one node)**
  - What happens: generator blocks until the next ms, increasing tail latency.
  - Detection: `logical_overflow_wait_ms` and P99 latency alarms.
  - Recovery: add pods or use batch requests.

## What I'd Do Differently At...

- **10x scale:** add a batch endpoint and make clients default to it.
- **100x scale:** push batch sizes up before changing bit allocation.

## Operational Notes

- Run `chrony` everywhere and **forbid NTP stepping** after boot; allow slew only. Stepping is the #1 cause of silent ordering bugs.
- Refuse to serve until time sync is healthy and the pod can write its `Lease`.
- Treat “skew fence trip” and “lease write stall” as paging incidents.
- Pick the custom epoch once; choose it so the ~34-year horizon matches your expected system lifetime.
