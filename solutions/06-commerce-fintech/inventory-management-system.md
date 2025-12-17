---
generation_time_seconds: 696
title: "Inventory Management System"
category: "Commerce & Fintech"
difficulty: "Hard"
tags: ["inventory", "reservations", "consistency", "payments", "concurrency"]
---

## Overview

This system tracks stock per SKU and supports **time-bound reservations** (“holds”) so checkout never oversells. The only strict requirement is the oversell gate, enforced by a single Postgres transaction; everything else can be stale and still correct because the write path is the authority.

The design is one service (the API) plus Postgres. Inventory changes are just idempotent state transitions on a reservation record guarded by one atomic predicate: `on_hand - reserved >= qty`.

## What Makes This Hard

Naive implementations model “available stock” as a read-modify-write value (or a cache entry) and then bolt on “holds” later. Under concurrency, retries, and partial failures (payment succeeds but commit fails, client retries, workers crash), this creates two classic traps:

1. **Double-decrement / double-release**: the same user action (or retry) mutates stock multiple times.
2. **Ghost inventory**: expired holds don’t get released promptly, so you under-sell; or worse, holds get ignored and you oversell.

The hard part isn’t “storing stock”—it’s making **reserve/commit/release** safe under retries and partial failures with one source of truth.

## Requirements

### Functional Requirements
- Create a reservation for `sku + qty` with a hold period (e.g., 10 minutes).
- Prevent oversell across concurrent reserve/checkout attempts.
- Convert a reservation into a purchase (commit) exactly once.
- Release a reservation on cancel, payment failure, or expiration.
- Idempotency for reserve/commit/release (clients and workers will retry).
- Fallback behaviors when the system is degraded (DB slow, timeouts).

### Scale Targets
- Catalog size: ~100k SKUs (long tail), with a few hot SKUs.
- Read traffic: 5k–20k RPS for “in stock?” and quantity snapshots (served from the API with short TTL caching).
- Write traffic: 200–1k RPS reservations during peak; commits proportional to checkout rate.
- SLO: reserve/commit p95 < 150ms (writes), availability reads p95 < 30ms (hot cache).
Why these matter: write latency drives checkout abandonment; hot-SKU contention drives correctness bugs.

## Key Design Decisions

- **We chose:** Postgres as the source of truth with transactional, conditional updates for stock.
  - **Rejected:** Redis-only counters / cache-as-source-of-truth.
  - **Why:** oversell prevention needs a single consistent authority; caches are for speed, not correctness.

- **We chose:** Explicit `reservations` table with a state machine + idempotency keys.
  - **Rejected:** “reserved_qty only” without per-reservation records.
  - **Why:** you need auditability and safe retries; counters alone can’t tell you what to undo.

- **We chose:** Set-based expiration directly from Postgres using `SKIP LOCKED`.
  - **Rejected:** per-reservation queueing and TTL-based “cleanup.”
  - **Why:** expiration is a business state transition; Postgres already provides safe batching and locking.

## Architecture

```mermaid
flowchart LR
  C[Client] --> A["API (Reserve/Checkout)"]
  A --> P[(Postgres)]
```

### Components

- **API (Reserve/Checkout)**: The only writer for inventory; serves reads with short TTL caching; runs the expiration loop as a background task.
- **Postgres**: The source of truth for inventory counters and reservation records; transactions are the oversell gate and the idempotency anchor.

## Deep Dive: Oversell Prevention With Holds (The Hardest Part)

### Data model (minimal but sufficient)

- `inventory(sku PK, on_hand INT, reserved INT, updated_at TIMESTAMPTZ)`
- `reservations(reservation_id PK, sku, qty, state ENUM('ACTIVE','COMMITTED','RELEASED','EXPIRED','REJECTED'), expires_at TIMESTAMPTZ, idempotency_key UNIQUE, request_hash BYTEA, created_at, updated_at)`
- Index: `reservations(state, expires_at)` (for expiry polling)

Invariant: `0 <= reserved <= on_hand` always holds in the *committed database state*.

### Reserve (create hold)

Single transaction:

1. **Idempotency check**: insert reservation row with `state='ACTIVE'`, `expires_at = now()+hold`, and `request_hash = hash(sku, qty, hold)`.
   - If `idempotency_key` already exists, return that row only if `request_hash` matches; otherwise fail.
2. **Conditional counter update (the oversell gate)**:
   ```sql
   UPDATE inventory
   SET reserved = reserved + :qty, updated_at = now()
   WHERE sku = :sku AND (on_hand - reserved) >= :qty;
   ```
3. If the update affects 0 rows, transition the reservation to `REJECTED` and return “out of stock”.

Why this works: the conditional update is the oversell gate. No distributed lock, no race—just a single atomic predicate on the authoritative counters.

### Commit (convert reservation to sale)

Single transaction:

1. Lock the reservation row (`FOR UPDATE`) and verify `state='ACTIVE'` and `expires_at > now()`.
2. Transition reservation to `COMMITTED` exactly once (`WHERE state='ACTIVE'`).
3. Decrement counters:
   - `reserved -= qty`
   - `on_hand -= qty`
4. If `expires_at <= now()`, transition `ACTIVE -> EXPIRED`, decrement `reserved`, and fail checkout.
5. If the reservation is already `COMMITTED`, return success (idempotent). If `RELEASED/EXPIRED/REJECTED`, fail checkout.

This avoids the classic “payment succeeded but inventory commit retried” bug: the reservation row is the idempotency anchor.

### Release / Expire (return stock)

Release is the same state transition whether initiated by user cancel, payment failure, or expiration:

- Transition `ACTIVE -> RELEASED` (or `ACTIVE -> EXPIRED`) only if still active.
- Decrement `inventory.reserved` by `qty`.

Expiration loop (runs in the API as a background task):
- In batches: `SELECT reservation_id FROM reservations WHERE state='ACTIVE' AND expires_at <= now() ORDER BY expires_at LIMIT :n FOR UPDATE SKIP LOCKED`
- For each, run the same transactional `ACTIVE -> EXPIRED` transition and reserved decrement.

### Why not “compute reserved from active reservations”?

Because summing active reservations per SKU turns hot SKUs into query hotspots, and “available” becomes expensive under load. Counters keep the critical path O(1) with predictable locking.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Correctness under retries/failures | Some write-path contention on hot SKUs |
| Few moving parts | Read-side staleness and less tail-latency control |
| Boring, operable tech (Postgres) | Multi-region active/active is non-trivial |

## Failure Modes

- **Postgres down / severely degraded**
  - *What happens:* reserve/commit fails fast; reads return “unknown” (or “out of stock”) and checkout blocks.
  - *Detect:* DB health checks, timeouts, connection pool saturation.
  - *Recover:* circuit-break writes; keep retries bounded; prefer undersell over oversell.

- **DB lock contention on hot SKUs**
  - *What happens:* reserve/commit p95 spikes; timeouts increase; users see “couldn’t reserve”.
  - *Detect:* lock wait time, deadlocks, high conflict rate on `inventory` rows.
  - *Recover:* aggressive timeouts + retry with jitter; rate-limit the hottest SKUs; keep transactions single-row and short.

- **Expiration lag**
  - *What happens:* reserved stays high; you under-sell until expiry catches up.
  - *Detect:* `now() - min(expires_at)` for `state='ACTIVE'`; count of expired-but-active rows.
  - *Recover:* run larger batches; keep the “commit treats expired as expired” rule to prevent late commits.

- **Client retries / duplicate calls**
  - *What happens:* the same request is replayed or the same idempotency key is reused with a different payload.
  - *Detect:* idempotency conflicts; request hash mismatches.
  - *Recover:* return the existing reservation on exact replay; reject mismatched replays deterministically.

- **Partial failure during checkout (payment vs commit)**
  - *What happens:* payment captured but reservation not committed (or commit retried).
  - *Detect:* mismatch between payments and committed reservations; “paid but not committed” alerts.
  - *Recover:* idempotent commit by `reservation_id`; if commit fails due to expiry/state, trigger refund and stop retrying.

## What We Removed

- **Queue**: expiration is polled from Postgres with `SKIP LOCKED`.
- **Dedicated Inventory Service**: inventory logic lives in the API as a module with a single writer path.
- **External read cache**: reads use short TTL caching inside the API; correctness comes from the write path.
- **`inventory.version`**: removed schema baggage; row locks + `updated_at` are sufficient here.
- **Delete-or-release on out-of-stock**: out-of-stock becomes `REJECTED` so idempotency returns the same outcome.

## Operational Notes

- Track three golden signals for inventory writes: `reserve_success_rate`, `reserve_latency`, `commit_idempotency_hit_rate` (high is good under retries).
- Index for expiry polling: `reservations(state, expires_at)`.
- Idempotency is strict: the first request binds `idempotency_key` to `sku, qty, hold` via `request_hash`.
- Lock ordering is fixed: lock `reservations` first, then mutate `inventory`.
- Treat “out of stock” responses during DB degradation as a deliberate safety fallback; oversell is worse than undersell.
