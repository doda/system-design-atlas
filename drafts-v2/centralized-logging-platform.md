```markdown
---
title: "Centralized Logging Platform"
category: "Observability & Reliability"
difficulty: "Hard"
tags: ["logging", "observability", "pii", "redaction", "search", "kafka", "opensearch", "s3", "clickhouse"]
---

## Overview

This platform centralizes logs with three guarantees: (1) PII is redacted before anything is searchable, (2) schema changes never break ingestion, and (3) engineers can do fast, time-bounded text search with predictable latency.

Logs follow a **stable envelope** (`timestamp/service/level/trace/span/message/attrs`). Everything outside the envelope stays in `attrs` and is not automatically indexed. A single **ingestion-time redaction boundary** decides what is allowed into search. The system keeps **hot search** in OpenSearch (7 days) and **cheap retention + replay** in S3/Parquet (180 days).

## What Makes This Hard

Naive logging platforms fail in two places:
1) **PII leaks via “just index everything.”** Once unredacted content lands in a search index, it gets replicated, cached, snapshotted, and copied into too many places to claw back.
2) **Schema drift turns into operational drift.** Dynamic mappings explode (OpenSearch) or schemas ossify (SQL), and teams either lose fields silently or break ingestion during deploys.

The trap is treating logs as “just text.” Logs are **semi-structured events** with privacy constraints and lifecycle management; you need a redaction boundary, a schema strategy, and a retention strategy that reinforce each other.

## Requirements

### Functional Requirements
- Ingest logs from services/hosts with at-least-once delivery and backpressure.
- Support schema evolution without coordinated deploys across producers and consumers.
- Enforce PII redaction/masking before any data becomes broadly accessible/searchable.
- Provide fast text search over recent logs with filters (time range, service, level, trace_id) and “tail -f” experience.
- Retain logs cost-effectively for compliance/forensics and allow reprocessing when parsers/redaction rules change.

### Scale Targets
- **Ingest:** 250k events/s average, 1M events/s peak (incident storms); avg 1.5KB/event → ~375MB/s avg, ~1.5GB/s peak.
- **Hot search retention:** 7 days indexed (engineers debug the “now”); **p95 query < 2s** for last 15 minutes, < 5s for last 24h.
- **Cold retention:** 180 days in object storage (cost + investigations); partitioned for batch scans.
- **Freshness:** searchable within 10 seconds (incident response requires near-real-time, not streaming-perfect).

## Key Design Decisions

- **Redaction boundary at ingestion**
  - Chose: one mandatory processing stage that parses + classifies + redacts before *any* searchable output exists.
  - Why: once PII is indexed, it cannot be reliably removed everywhere.

- **Stable envelope + schemaless attributes**
  - Chose: fixed top-level columns + `attrs` map for everything else; the index only promotes an explicit allowlist.
  - Why: it prevents mapping explosions and makes schema evolution boring.

- **Two-tier storage: OpenSearch (hot) + S3/Parquet (cold)**
  - Chose: OpenSearch for low-latency text search; S3/Parquet for cheap retention and reprocessing.
  - Why: different workloads want different storage; pretending one engine does both well creates on-call pain.

- **End-to-end idempotency**
  - Chose: deterministic `event_id` computed in the processing stage (content-hash + source metadata); OpenSearch uses it as `_id`.
  - Why: at-least-once delivery is the default; duplicates must not multiply in hot search.

## Architecture

```mermaid
flowchart LR
  A[Agents] --> C[Kafka (raw + tail + quarantine)]
  C --> D[Redact + Enrich]
  D --> E[OpenSearch (7d)]
  D --> F[S3 Parquet (180d)]
  D --> C
  H[UI + CLI] --> E
  H --> C
  H --> F
```

### Components

- **Agents (Fluent Bit/Vector):** ship logs with local buffering/backpressure and add host metadata; this is the only way to survive host/network churn.
- **Kafka:** absorbs spikes, decouples ingestion from downstream outages, and provides replay by offset for policy/parser changes.
- **Redact + Enrich (Kafka Streams):** the single enforcement point that normalizes into the stable envelope, applies PII rules, verifies, and then emits only safe outputs.
- **OpenSearch (hot):** the only interactive search store; everything indexed is already redacted and schema-controlled.
- **S3 Parquet (cold):** cheap retention for 180 days: redacted Parquet for investigations plus raw encrypted objects (restricted) to enable true reprocessing.
- **UI + CLI:** hot search via OpenSearch, tail via the redacted Kafka stream, and cold investigations via S3/Parquet batch queries.

## Deep Dive: PII Redaction With Guarantees (Without Killing Search)

PII-safe is a property of the pipeline, not a convention. The design uses three reinforcing layers:

1) **Allowlist-first schema handling.** The only fields promoted to top-level indexed columns are an explicit allowlist (`timestamp`, `service`, `level`, `trace_id`, `span_id`, `message`, `attrs`). Everything else stays inside `attrs` as strings. This prevents accidental indexing of new fields that appear during deploys.

2) **Deterministic masking with keyed tokens.** For common PII (email, phone, IP, account ids), the processor replaces matches with typed tokens:
   - `alice@example.com` → `<email:hmac=…>`
   Tokens use **per-tenant/per-environment HMAC** so exact-match workflows stay possible without cross-tenant correlation. Rotation is handled by replaying Kafka offsets into the new key version.

3) **Post-redaction verification + quarantine.** After masking, the processor runs a second detection pass. If it still detects high-confidence PII (or parsing fails), it routes the event to a **quarantine topic** that is:
   - not indexed,
   - short-retention,
   - restricted access,
   - fully audited.
This prevents silent leakage and gives a clean workflow: fix rule → replay Kafka offsets → backfill safe outputs.

This approach teaches a non-obvious lesson: **the only reliable way to prevent PII in search is to treat indexing as a privilege granted after verification**, not as the default outcome of ingestion.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| PII safety by construction | Raw-log convenience in search |
| Predictable search latency (hot window) | Single-store simplicity |
| Schema agility without breakage | Some fields stay unindexed unless promoted |
| Reprocessing and auditability | Extra pipeline stage to operate |
| Hot-search correctness under retries | Cold storage can contain duplicates (dedup by `event_id`) |

## Failure Modes

- **OpenSearch cluster degradation (red/yellow, high heap, slow queries)**
  - Happens: indexing lags; queries time out.
  - Detect: rejected writes, heap pressure, query p95 spikes, processor sink errors.
  - Recover: keep ingesting into Kafka, pause indexing if needed, roll indices more aggressively, and keep tail working from Kafka’s redacted stream.

- **PII redaction regression**
  - Happens: new pattern leaks PII; risk is systemic.
  - Detect: verifier hit-rate and quarantine rate spikes.
  - Recover: stop indexing, fix the rule, replay offsets, and (if a token key was wrong) rotate the HMAC key version and replay.

- **Kafka backlog during incident storm**
  - Happens: downstream can’t keep up; lag grows; “near real-time” becomes minutes.
  - Detect: consumer lag alarms per partition and agent-side buffering growth.
  - Recover: scale processors horizontally, reduce enrichment cost, shed non-critical sources, and prioritize the redaction stage over indexing.

- **Quarantine flood (parser bug or rule mismatch)**
  - Happens: a large fraction of events route to quarantine and threaten Kafka disk.
  - Detect: quarantine rate spikes and quarantine topic retention pressure.
  - Recover: lower quarantine retention, stop indexing, fix the parser/rules, and replay offsets to regenerate safe outputs.

- **Kafka outage / partition unavailability**
  - Happens: producers cannot append; ingest stalls.
  - Detect: broker health alarms, produce error rates from agents.
  - Recover: agents buffer locally up to a fixed cap, then drop oldest; ingestion is disabled rather than acknowledged without durability.

- **Duplicates from at-least-once**
  - Happens: retries and replays emit the same event multiple times.
  - Detect: rising duplicate overwrite rate in OpenSearch (same `_id`), cold-store dedup rate in batch queries.
  - Recover: `event_id` is deterministic in the processor; OpenSearch uses `_id = event_id` and overwrites; cold investigations dedup by `event_id`.

## What We Removed

- The ingest gateway: agents write to Kafka directly; Kafka ACLs and TLS provide the boundary.
- The query API: hot search is OpenSearch, tail is the redacted Kafka stream, cold is S3/Parquet batch queries.
- The “future scale” re-architecture (ClickHouse, caches, extra tail services): the system stays one pipeline and two stores.

## Operational Notes

- Keep OpenSearch mappings tight: index only a small set of fields; store `attrs` as a single flattened object or non-indexed blob to prevent mapping explosion.
- Enforce index lifecycle: roll daily/hourly, hot→warm→delete; size shards for recovery speed, not just throughput.
- Treat redaction rules as code: versioned, reviewed, tested against fixtures; deploy with canaries and a “stop indexing” kill switch.
- Build “replay by offset” tooling: every incident response eventually needs “reprocess yesterday with the new parser.”
- Audit everything that touches quarantine or any reversible tokenization; assume those logs will be requested during an investigation.
```
