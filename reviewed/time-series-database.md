---
title: "Time-Series Database (TSDB)"
category: "Storage & Data Platforms"
difficulty: "Hard"
tags: ["tsdb", "storage-engine", "iot", "metrics", "observability", "distributed-systems"]
---

## Overview

A time-series database (TSDB) for IoT telemetry and metrics must ingest high write rates (mostly append-only), store data efficiently (compression + partitioning), and answer low-latency queries over recent data while still supporting long-range analytics through downsampling and retention tiers.

The hard problems are usually not “writing points to disk”, but sustaining predictable performance under:
- **High-cardinality tags** (e.g., `device_id` across millions of devices)
- **Hot partitions** (skewed traffic by tenant/region/metric)
- **Out-of-order and duplicate data** (retries, device clock skew, intermittent connectivity)
- **Background work** (compaction, rollups, tiering) competing with ingestion and queries
- **Multi-tenancy** (quotas, isolation, noisy-neighbor control)

A production TSDB typically separates concerns by time and workload:
1. **Write path**: fast durable acceptance via a replicated commit log, then local WAL + in-memory buffering, flushing into immutable, time-partitioned blocks.
2. **Read path**: tag/label index + per-block metadata to prune aggressively and minimize IO.
3. **Background pipeline**: compaction, downsampling, retention, and tiering with strict resource budgets so it can’t starve ingestion/query.

This design yields stable ingestion, bounded query latency, and controllable storage cost.

## Requirements

### Functional Requirements
- Ingest telemetry points with: metric name, tags/labels, timestamp, and numeric value(s) (e.g., gauge/counter).
- Support **idempotent writes** for retries and **de-duplication**; tolerate **out-of-order arrivals** within a configurable window (e.g., 2 hours).
- Query by time range with tag filters and aggregations (sum/avg/min/max, rate/increase for counters, percentile approximations).
- Provide downsampling rollups (e.g., raw → 1m → 10m → 1h) with configurable aggregations per metric.
- Enforce retention policies per tenant/namespace (e.g., raw 7d, 1m 90d, 1h 2y) and tier data across hot/warm/cold storage.
- Support multi-tenancy: per-tenant quotas (ingest rate, max series cardinality), isolation, and authn/authz.
- Expose operational APIs: health, shard status, backpressure signals, compaction/rollup progress.
- Support bounded backfill imports and safe deletes (tombstones) for GDPR/tenant offboarding.

### Non-Functional Requirements (SLOs, Scale, and Targets)

#### Workload Assumptions (Example Sizing)
- **Devices**: 1,000,000 registered, ~200,000 concurrently active.
- **Ingest peak**: **2,000,000 samples/sec** cluster-wide.
  - If clients batch ~200 points/request, that’s ~10,000 req/sec at peak.
- **Series cardinality** (active, queried):
  - Global: **50M–300M active series** (depends heavily on tag design and device churn).
  - Large tenant: **1M–20M active series**.
- **Out-of-order window**: default 2 hours; per-tenant configurable (smaller is cheaper).

#### Storage Math (Correct Order-of-Magnitude)
- **Daily points** at 2M/s: `2,000,000 * 86,400 ≈ 172.8B points/day`.
- **On-disk raw footprint** depends on encoding and chunking; a realistic planning range for “timestamp + value + per-sample overhead” is **8–20 bytes/point** in hot storage (before tag index and manifests):
  - Raw samples/day: ~**1.4–3.5 TB/day**
  - Add index/manifests + replication + headroom: plan for **3–10 TB/day effective** cluster capacity growth at peak
- Downsampling and tiering shift most long retention to object storage (lower $/TB).

#### Latency Targets (Achievable with This Architecture)
- **Writes (acknowledged)**: P50 10–20 ms, P99 50–100 ms (ack after replicated commit-log quorum).
- **Queries**:
  - “Recent dashboard” (last 1h, selective tags): P50 30–80 ms, P99 200–500 ms
  - “Long range” (30d, downsampled): P99 1–3 s
- Latency is workload-dependent; the system must enforce query cost limits to keep P99 bounded.

#### Availability & Durability
- **Availability**: 99.99% within a region for reads/writes (tolerate single node / single zone failures).
- **Durability**: no acknowledged write loss within a region.
- **Cross-region DR**: async replication to meet **RPO 5 minutes**, **RTO 30 minutes** (degraded semantics during failover).

#### Consistency Model
- **Metadata** (tenants, limits, retention, placement): strongly consistent.
- **Data**:
  - A write is “durable” once it is in the **replicated commit log quorum**.
  - Query visibility is typically **near-real-time** and can be made “read-your-writes” per client by using a **write receipt/watermark** (see “Consistency & Correctness”).

### Constraints & Assumptions
- Team size ~6–10 engineers; prefer proven building blocks (Raft KV for metadata, object storage for cold tier).
- Kubernetes deployment; NVMe for hot tier; object storage (S3/GCS) available; cross-region bandwidth is expensive.
- TLS everywhere; per-tenant encryption-at-rest keys (KMS); audit logs for admin actions.
- Query model is metrics-style (PromQL-like filters + aggregations), not arbitrary SQL joins.

## Architecture

### High-Level Component Diagram

```mermaid
flowchart LR
  subgraph Clients
    C[IoT Devices / Apps]
    D[Dashboards / Analytics]
  end

  subgraph ControlPlane[Control Plane]
    MS[Metadata Store<br/>(Raft KV)]
    PM[Placement / Shard Map]
    RM[Retention & Rollup Policies]
  end

  subgraph DataPlane[Data Plane]
    LB[Edge LB]
    IA[Ingest API]
    QA[Query API]
    CL[Commit Log<br/>(replicated)]
    subgraph Storage[TSDB Storage Nodes]
      SN1[TSDB Node A]
      SN2[TSDB Node B]
      SN3[TSDB Node C]
    end
    BG[Compaction / Rollup Workers]
    OS[(Object Storage)]
    CC[(Hot Block/Chunk Cache)]
  end

  C --> LB --> IA
  D --> LB --> QA

  IA --> PM
  QA --> PM

  PM <--> MS
  RM <--> MS

  IA --> CL
  CL --> SN1
  CL --> SN2
  CL --> SN3

  QA --> SN1
  QA --> SN2
  QA --> SN3

  SN1 <--> CC
  SN2 <--> CC
  SN3 <--> CC

  BG --> SN1
  BG --> SN2
  BG --> SN3
  BG <--> OS
  SN1 <--> OS
  SN2 <--> OS
  SN3 <--> OS
```

### Why This Separation Works
- **Commit log** absorbs bursts and provides ordered, replicated durability independent of on-disk block layout.
- **TSDB nodes** optimize local storage and query pruning (WAL/memtable/blocks + tag index).
- **Background workers** handle expensive tasks (compaction/rollups/tiering) under budgets so foreground SLOs remain stable.
- **Metadata store** keeps placement/config consistent and auditable.

## Components

### Ingest API
**Responsibility**: authn/authz, validation, batching, routing, idempotency, backpressure.

**Key design decisions**
- **Shard-aware routing** using a placement ring (`tenant_id` + hash of series) to keep writes local and predictable.
- **Backpressure** via explicit signals: `429` (tenant throttles) vs `503` (cluster overload) with retry hints.
- **Cardinality protection**: per-tenant caps + “new series” rate limits to prevent tag explosions.

**Implementation notes**
- Stateless service in Go/Java; gRPC internally, HTTP/JSON optional for client simplicity.
- Enforce limits early (before commit log) to protect shared infrastructure.

### Commit Log (Durable Write Buffer)
**Responsibility**: durable replication and ordering of writes before they are applied to storage blocks.

**Key design decisions**
- Partition by **(tenant, shard)** (or shard-group) to preserve order per shard and simplify consumer state.
- Short retention (hours to days). The commit log is not the database; it is a durability and replay layer.

**Technology options**
- Kafka/Pulsar for large scale and operational maturity.
- A built-in Raft log per shard-group for smaller deployments (simpler footprint, higher engineering cost).

**Operational requirements**
- RF ≥ 3 across zones, rack-aware placement.
- Enforce quotas per tenant to prevent a single tenant from saturating the log.

### TSDB Storage Nodes (Storage Engine)
**Responsibility**: store samples, maintain tag index, serve scans/aggregations, run compaction locally.

**Write path**
- Append to **local WAL** (fast recovery) and update **memtable/head**.
- Flush immutable **blocks** on time/size boundaries (e.g., 2h windows, plus max block size).
- Maintain block metadata (time bounds, series/chunk offsets, optional bloom filters).

**Read path**
- Use **tag index** to find candidate series (postings lists).
- Use **block metadata** to prune blocks by time range and (optionally) series presence.
- Read and decode only necessary chunks; stream partial aggregations back to Query API.

**Encoding**
- Timestamps: delta-of-delta + varint (or RLE when steady).
- Values: Gorilla XOR (floats), delta + zigzag (ints).
- Optional chunk-level min/max to accelerate some aggregations.

**Index**
- Series dictionary mapping `(metric, sorted tags)` → `series_id`.
- Inverted index per `(tag_key, tag_value)` → postings list of `series_id` (Roaring bitmaps or compressed lists).

### Query API
**Responsibility**: parse/plan queries, shard fan-out, distributed aggregation, caching, pagination/streaming.

**Key design decisions**
- Predicate pushdown: time range + tag filters evaluated on storage nodes.
- Two-stage aggregation: per-shard partials then merge (reduces network).
- Cost-based admission control: limit fan-out, bytes scanned, series matched, and CPU time per tenant/query.

**Tail-latency controls**
- Bounded concurrency per query and per tenant.
- Hedged requests for slow shards (careful to avoid amplification).
- Optional partial results with warnings for timeouts (configurable by tenant).

### Rollup & Retention Manager
**Responsibility**: downsampling, tiering hot→warm→cold, deletion/tombstones, backfill coordination.

**Key design decisions**
- Store rollups as separate **resolutions** (raw, 1m, 10m, 1h) to avoid mixing granularities in one block.
- Tier by block age:
  - Hot: local NVMe, recent blocks and index
  - Warm: cheaper local disks (or less cache)
  - Cold: object storage for older/downsampled blocks + local cache for popular reads

**Downsampling strategy**
- Continuous rollups computed during/after compaction.
- For percentiles, store mergeable sketches (e.g., t-digest) per time bucket.

## Data Model

### Logical Model
- **Tenant**: isolation boundary for quotas, auth, retention, encryption keys.
- **Series**: unique `(metric_name, sorted tags)` mapped to `series_id`.
- **Sample**: `(series_id, timestamp_ms, value[, field])`.

### Metadata (Strongly Consistent)
Stored in a small replicated metadata store (Raft KV):
- `tenants(tenant_id, limits, retention_policies, kms_key_ref, created_at)`
- `placement(shard_id -> [replica_nodes], epoch, updated_at)`
- `series_dict(tenant_id, series_id, metric, tags_hash, tags_kv, created_at, last_seen_at)`
- `index_manifest(tenant_id, shard_id, resolution, block_id -> location, stats, checksum)`

Notes:
- `series_dict` can become very large at extreme scale; a common split is:
  - Hot in-memory on nodes for recently-seen series + persistent store for cold series metadata.
  - Alternatively, store only `series_id -> tags` in a compressed store and keep tag index + hash as primary lookup.

### Block/Segment Layout (Immutable)
- Block window: e.g., **2 hours** for raw; larger for rollups.
- Path: `{tenant}/{shard}/{resolution}/{start}-{end}/{ulid}.block`
- Block metadata:
  - `min_time`, `max_time`
  - `series_count`
  - `chunk_index` (offsets per series/chunk)
  - `bloom` (optional series presence)
  - `checksums` and format version
- Data:
  - Columnar-ish per-series chunks for efficient scans and compression.
  - Chunk-level encoding and optional min/max.

### Retention & Tiering
Example:
- Raw: 7 days (hot 48h on NVMe, warm remaining on cheaper disks)
- 1m: 90 days (warm/cold)
- 1h: 2 years (cold on object storage)

## API

### Write API
`POST /v1/write`

Headers:
- `Authorization: Bearer ...`
- `X-Tenant-Id: ...`
- `Idempotency-Key: ...` (recommended)

Body (JSON example; protobuf recommended for throughput):
```json
{
  "points": [
    {
      "metric": "temp_c",
      "tags": { "device_id": "d1", "region": "us" },
      "ts_ms": 1734390000123,
      "value": 21.4
    }
  ],
  "accept_out_of_order_ms": 7200000
}
```

Responses:
- `204 No Content` success
- `400` invalid metric/tags/timestamp
- `401/403` authn/authz failures
- `409` idempotency key reused with different payload
- `413` payload too large
- `429` tenant throttled (rate/cardinality)
- `503` overload/backpressure (retry with jitter + respect `Retry-After`)

Idempotency semantics:
- If `Idempotency-Key` is present, the server stores a short-lived record keyed by `(tenant_id, key)` with:
  - request hash, status, and (optionally) error body
- Replays return the same outcome; conflicting payload returns `409`.

Duplicate samples:
- De-duplication at storage can be configured per metric:
  - **last-write-wins** for gauges
  - **reject duplicates** for strict pipelines
  - **sum duplicates** is generally unsafe unless explicitly desired

### Query API
`POST /v1/query`

Body:
```json
{
  "start_ms": 1734386400000,
  "end_ms": 1734390000000,
  "filter": {
    "metric": "temp_c",
    "tags": { "region": "us" }
  },
  "downsample": { "resolution": "1m", "agg": "avg" },
  "group_by": ["device_id"],
  "limit_series": 10000
}
```

Response:
```json
{
  "series": [
    {
      "tags": { "device_id": "d1" },
      "points": [[1734386460000, 21.1]]
    }
  ],
  "warnings": []
}
```

Errors:
- `400` invalid query
- `413` query too expensive (exceeds cost limits)
- `429` query throttled (tenant budget)
- `504` shard timeout (optionally return partials with warnings)

### Discovery APIs
- `GET /v1/labels` → list tag keys (paginated)
- `GET /v1/label/{key}/values` → list values (paginated)
- `POST /v1/series` → match series by filter, returns series IDs/tags (paginated)

### Admin / Ops APIs
- `GET /v1/health`
- `GET /v1/shards` (placement + lag + disk/compaction stats)
- `PUT /v1/tenants/{id}/retention` (audited, RBAC-protected)

## Scaling

### Partitioning & Sharding
- Primary isolation: `tenant_id`
- Within tenant: `shard = hash(series_id) % N`
- Time partitioning: immutable blocks per time window inside each shard
- Replication: shard replicas across zones (e.g., RF=3)

Practical guidance:
- Choose shard counts to keep per-shard ingestion and index sizes manageable (avoid “one massive shard”).
- Allow **resharding** (split/merge) for large tenants; treat it as an operationally significant workflow.

### Bottlenecks and Mitigations
- **High-cardinality tags** (index blow-up)
  - Cardinality caps, “new series” rate limits, tag allow/deny lists
  - Educate users: avoid unbounded tags (e.g., `trace_id`, raw URLs)
  - Approximate counting (HLL) per tenant/metric to detect explosions early
- **Skew / hot shards**
  - Hash on series ID (not device ID alone), enable shard splitting for large tenants
  - Adaptive throttling per tenant and per shard
- **Compaction debt**
  - Separate compaction IO/CPU budgets
  - Autoscale storage nodes by compaction backlog and disk pressure (not just CPU)
- **Query fan-out**
  - Aggressive pruning via time + tag index
  - Cost-based admission control and caching for dashboards
  - Precompute rollups; enforce “use rollup for >X days” policies

### Caching Strategy
- **Index cache**: hot postings + series dictionary in RAM; size-bounded.
- **Block metadata cache**: headers and sparse indices for fast pruning.
- **Chunk cache**: LRU for frequently-read chunks (dashboards).
- **Query result cache**: short TTL (5–30s), keyed by tenant + query + time bucket + resolution.
- Invalidation: mostly TTL-based; optionally include a per-shard ingestion watermark in the cache key for recent ranges.

## Consistency & Correctness

### Write Durability vs Read Visibility
- A write is acknowledged after commit-log quorum append, which guarantees durability but may precede application on every storage node.
- To support “read-your-writes” when needed:
  - Return a **write receipt** containing `(shard_id, log_offset)` (or a logical timestamp/watermark).
  - Query requests can include `min_visibility` per shard; the query layer waits (bounded) until storage nodes have applied up to that offset, otherwise returns partial + warning or times out.

### Out-of-Order Handling
- Accept out-of-order within a configured window; beyond the window either:
  - reject (cheapest and simplest), or
  - route to a backfill path that writes into separate blocks (more expensive).
- Compaction must reconcile out-of-order samples and tombstones deterministically.

### Deletes and GDPR
- Implement deletes as **tombstones** applied during compaction (and enforced at query time).
- For hard-delete guarantees, track completion per block and expose auditability (what was deleted, when, and in which tiers).

## Failure Modes

### Failure Scenarios & Mitigations
- **TSDB node crash (disk OK)**
  - Impact: replica unavailable; possible lag until replacement catches up.
  - Mitigation: placement detects failure, reassigns replica; node replays local WAL and/or commit log from last checkpoint.
- **Zone failure**
  - Impact: loss of multiple replicas in one zone.
  - Mitigation: RF across zones; quorum-based durability; continue with reduced capacity; block re-replication when zone returns.
- **Commit log partition/broker failure**
  - Impact: ingest stalls for affected partitions.
  - Mitigation: RF≥3, rack-aware; producer `acks=all`; client retries with jitter; operational playbook for partition reassignment.
- **Metadata store outage**
  - Impact: placement changes blocked; steady-state reads/writes can continue using cached placement until TTL.
  - Mitigation: multi-node Raft; strict quorum; cached ring with conservative TTL; disable rebalancing during outage.
- **Compaction falls behind (debt grows)**
  - Impact: read amplification and disk pressure; p99 spikes.
  - Mitigation: throttle new series and/or ingestion; scale storage; prioritize critical compactions; enforce compaction budgets.
- **Object storage degradation/outage**
  - Impact: cold queries fail/slow; tiering may pause.
  - Mitigation: local caching; graceful degradation (serve warm only); retry with backoff; alert and throttle cold-range queries.
- **Clock skew / extreme out-of-order**
  - Impact: rejected writes or misleading query results.
  - Mitigation: server-side timestamp option; per-tenant skew monitoring; configurable accept window; device fleet guidance.
- **Corrupt block / checksum failure**
  - Impact: data loss for a replica; query errors.
  - Mitigation: per-block checksums; redundant replicas; repair by re-fetching from another replica or object store; alert on corruption.

### Disaster Recovery (Cross-Region)
- Targets: **RPO 5 minutes**, **RTO 30 minutes**.
- Backups:
  - Metadata store snapshots (e.g., every 15 minutes) + WAL/manifest checkpoints.
  - Object storage buckets are versioned; manifests are immutable and checksummed.
- Failover:
  - Warm-standby region restores metadata snapshot + applies replicated manifests.
  - Data plane can be “single-writer per tenant” to avoid conflict; during failover, accept that the most recent few minutes may be missing (RPO).

## Operations

### Monitoring & Alerting
Key metrics:
- Ingest: points/sec, request errors, throttles, p99 latency, commit-log append latency, queue depth
- Storage: WAL fsync latency, memtable flush time, compaction debt, disk usage, read amplification, checksum failures
- Index: postings size, cache hit rate, series cardinality per tenant/metric, “new series/sec”
- Query: fan-out count, p99 latency, timeouts, bytes scanned, cache hit rate, partial result rate

Example alerts:
- Write error rate > 1% for 5m
- Commit-log under-replicated partitions > 0 for 5m
- Disk usage > 85% (warn), > 92% (critical)
- Compaction debt increasing for 30m (or time-to-compaction SLA breached)
- Cardinality growth anomaly per tenant/metric
- Query partial result rate > threshold for 10m

### Deployment & Upgrades
- Rolling upgrades with compatibility gates:
  - Block format versioning; read compatibility for N-1
  - Canary rollout for a subset of shards/tenants
- Safe rollbacks:
  - Feature flags for compaction/rollup behavior
  - Avoid irreversible format changes without dual-read/dual-write migration
- Data migrations:
  - Background re-compaction to new formats; throttle to protect p99 SLOs

### Security
- TLS everywhere; mTLS for internal services where feasible.
- AuthN/Z via JWT/OIDC; tenant isolation enforced at every API boundary.
- Encryption at rest:
  - Per-tenant KMS key references for metadata + block encryption (envelope encryption).
- Audit logs for admin actions and retention policy changes.

### Cost Controls
- Enforce retention and rollups; make “raw beyond X days” opt-in and expensive.
- Encourage best practices for tags (bounded sets) to reduce index and query costs.
- Prefer object storage for long retention; keep hot footprint small and predictable.

## Trade-offs

### Key Trade-offs Made
- **Ack after replicated commit log, not after block flush**
  - Pros: low-latency durable writes; handles bursts well.
  - Cons: read visibility is slightly delayed unless using watermarks; more moving parts (log + consumers).
- **Inverted tag index**
  - Pros: enables selective queries; avoids full scans.
  - Cons: write amplification and memory pressure under high cardinality; requires strict tenant guardrails.
- **Immutable time-partitioned blocks + compaction**
  - Pros: high compression; efficient scans; predictable file layout.
  - Cons: compaction debt can hurt tail latency if not budgeted; deletes are complex (tombstones).
- **Multi-tier storage (NVMe + object store)**
  - Pros: cost-effective long retention.
  - Cons: cold queries are slower and depend on object store availability; requires caching strategy.

### Alternative Approaches (When to Choose Them)
- **Prometheus + remote write + Thanos/Cortex/Mimir**
  - Great for metrics ecosystem and operational maturity; excellent when your data fits the Prometheus model and cardinality is controlled.
- **Cassandra/Scylla wide-row schema**
  - Can work for append-heavy time-bucket writes; struggles for flexible tag queries unless you precompute many access patterns; tombstones and compaction can be painful.
- **Lakehouse (Parquet on S3 + Trino/Spark)**
  - Best for batch analytics and ad hoc SQL; typically needs a separate hot serving layer to meet low-latency dashboarding.
- **Single-node TSDB per tenant**
  - Simple isolation; works for small tenants; operationally heavy at high tenant counts and makes cross-tenant querying harder.

## References & Further Reading
- Facebook Gorilla: compression techniques for time series
- InfluxDB TSM: WAL, compaction, segment files
- Prometheus TSDB: blocks, postings index, compaction strategy
- Uber M3DB: distributed TSDB, placement, commit logs
- Thanos/Cortex/Mimir: object storage + query federation patterns