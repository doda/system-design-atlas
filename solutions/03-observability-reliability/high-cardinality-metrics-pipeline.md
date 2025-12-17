---
generation_time_seconds: 716
title: "High-Cardinality Metrics Pipeline"
category: "Observability & Reliability"
difficulty: "Hard"
tags: ["metrics", "tsdb", "prometheus", "cortex", "multitenancy", "object-storage", "cardinality", "indexing", "query-engine"]
---

## Overview

This system ingests Prometheus `remote_write` at very high volume across many tenants, stays stable during cardinality spikes, and serves PromQL over both recent (“hot”) data and long retention (“cold”) data.

The design is a single, proven metrics backend (Cortex/Mimir-style) deployed in two roles: **stateless API** and **stateful ingesters**. Ingesters own the hot window with a WAL; they periodically cut immutable TSDB blocks and upload them to object storage. Queries read hot data from ingesters and cold data from object storage, with strict per-tenant limits so one tenant cannot destabilize the cluster.

## What Makes This Hard

1. **Cardinality is a memory/index failure mode, not a traffic problem.** A label blow-up creates new series, which blows up head state and index fanout before you “run out of CPU.”
2. **PromQL can be a DoS tool.** Without hard budgets, a single query (or dashboard) can saturate CPU and object-store reads.

## Requirements

### Functional Requirements
- **Prometheus remote_write-compatible ingest** with per-tenant isolation.
- **Cardinality controls**: per-tenant series limits, label allow/deny lists, and hard rejection with clear reasons.
- **Fast queries for recent data** and acceptable latency for long-range queries (hours–months).
- **Long-term retention** (months to years) on inexpensive storage.
- **Safe multi-tenant query execution**: no query can destabilize the cluster.

### Scale Targets
- Ingest: **10M samples/sec** sustained, **50M samples/sec** bursts (flash release + autoscaling lag).
- Active series: **200M global**, with **hard per-tenant caps** (e.g., 1–10M depending on plan).
- Retention: **13 months** raw at 10–15s for “gold” tenants; cheaper tiers use shorter retention and/or a larger scrape interval at the source.
- Queries: **p95 < 2s** for last 15m; **p95 < 8s** for 30d; concurrency in the low thousands.

## Key Design Decisions

- **Decision 1: Use an existing Cortex/Mimir-style backend**
  - Chose: One codebase that already implements multi-tenancy, TSDB blocks, rings, and query protection.
  - Why: This problem is operational edge-cases; “build” is the wrong simplification.

- **Decision 2: Hot head + immutable blocks**
  - Chose: Ingester head (WAL-backed) for the hot window; immutable TSDB blocks in **S3/GCS** for long retention.
  - Why: Immutable blocks make storage cheap, compaction safe, and reads cacheable.

- **Decision 3: Tenant isolation via shuffle sharding + hard limits**
  - Chose: Each tenant maps to a stable subset of ingesters; enforce `max_active_series`, `max_new_series_per_sec`, label limits, and sample-rate limits inside that shard.
  - Why: You get a mechanically true blast-radius boundary without a global “perfect” coordinator.

- **Decision 4: Query safety via coarse budgets**
  - Chose: Hard caps on time range, minimum step, max concurrency, and max execution time; split long range queries by time and cache subresults in-process.
  - Why: Fine-grained “query cost estimation” is complexity that fails under real workloads; coarse budgets are predictable.

- **What We Removed**
  - Separate `Ingest Gateway`, `Query Frontend`, and `Store Gateway` as standalone services (merged into one backend).
  - External ring KV store dependency (use gossip membership; reject writes when the ring is unstable).
  - Downsampling pipeline (tiers are retention + source resolution, not post-processing).
  - Dedicated query scheduler/worker pool (only add when query burst smoothing becomes necessary).

## Architecture

```mermaid
flowchart LR
  A[Prometheus / Agents] --> B["Metrics Backend (Cortex/Mimir-style)"]
  B <--> C["Object Storage (S3/GCS)"]

### Components

- `Prometheus / Agents`
  - Scrape locally and `remote_write` with backoff and batching. Retries are expected; ingestion is at-least-once.

- `Metrics Backend (Cortex/Mimir-style)`
  - What it does: auth + per-tenant limits, sharding and replication, WAL-backed hot ingest, query execution with strict budgets, block shipping, and compaction/retention as a background job.
  - Why it stays: it’s the only custom logic you can’t outsource—multi-tenant limits + TSDB semantics + query safety.
  - Ring and fencing:
    - Membership is gossip-based; token ownership is persisted so restarts don’t reshuffle.
    - Writes are acknowledged only after **quorum WAL durability**; if quorum can’t be reached or the ring isn’t stable, the API returns `503` so clients back off instead of creating split-brain data.
  - Limits rollout:
    - Limits are versioned; rollout is staged per tenant; “dry-run” mode reports would-reject before enforcement; revert is instant.

- `Object Storage`
  - Stores immutable blocks for long retention. This is the long-term source of truth.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Stability under cardinality spikes | “Accept everything” convenience |
| Small team operability (few moving parts) | Less independent scaling of query vs ingest roles |
| Cheap long retention | Historical queries depend on object-store health |
| Predictable multi-tenant fairness | Some queries are rejected instead of “slow but eventually” |

## Failure Modes

- **Ring instability or membership flapping**
  - What happens: shard ownership is uncertain; replication sets change too often to be safe.
  - Recover: stop acknowledging writes (`503`) until the ring is stable; keep serving hot reads from healthy ingesters.

- **Network partition (split-brain risk)**
  - What happens: two sides may disagree on ownership.
  - Recover: quorum writes + “ring must be stable” gating means partitions turn into rejected writes, not divergent acknowledged data.

- **Object storage slow/erroring for hours**
  - What happens: cold reads get slow; compaction falls behind.
  - Recover: keep hot queries served from ingesters; strictly shed long-range queries first; pause/slow background compaction to avoid LIST/GET storms and let the backlog accumulate.

- **Bad limits/config rollout rejects healthy tenants**
  - What happens: sudden, widespread ingest failures.
  - Recover: staged rollout + dry-run prevents global surprises; revert to the previous version immediately.

- **Tenant cardinality incident**
  - What happens: one tenant tries to create unlimited new series.
  - Recover: reject new series for that tenant inside its shard; quarantine the tenant if needed; keep everyone else stable.

## What I'd Do Differently At...

- **10x scale:** add a dedicated store-gateway/read-cache layer only if object-store amplification dominates; add SSD caches before adding more services.
- **100x scale:** split query execution into a scheduler + workers only if fairness and burst smoothing can’t be met with per-tenant queues and caps.

## Operational Notes

- Limits are the product contract: keep them visible, versioned, and easy to revert.
- Page on ring instability, WAL replay time, and compaction backlog age; those are the real “system is dying” signals.
- Make “partial results” explicit: only allow them by tenant policy, never silently.
