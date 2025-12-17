---
generation_time_seconds: 922
title: "Ledger Database"
category: "Storage & Data Platforms"
difficulty: "Hard"
tags: [ledger, banking, double-entry, append-only, cryptographic-audit, postgres]
---

## Overview

This system is a banking ledger: an immutable, append-only record of economic events with double-entry enforcement and cryptographic verification that the history hasn’t been tampered with.

One database (Postgres) is the source of truth. One service accepts requests and runs a single per-ledger committer loop that serializes entries into hash-linked blocks, signs them, and serves inclusion proofs.

## What We Removed

- Dedicated `Queue` → replaced by Postgres `entry_intents` with `SELECT ... FOR UPDATE SKIP LOCKED` and optional `LISTEN/NOTIFY`.
- `Object Store` for proof artifacts → proofs are served from Postgres (store per-entry Merkle paths per block).
- Separate `Anchor Service` → anchoring is an async loop in the same service.
- `Read Replica` → removed; correctness does not depend on it.

## Requirements

### Functional Requirements

- Record journal entries as multiple postings across accounts such that, per currency, postings net to zero.
- Prevent mutation: no updates/deletes; corrections are reversals (new entries).
- Provide reads for:
  - Account balance as-of time `T`
  - Journal entry lookup by id / external reference
  - Audit export (time-ordered)
- Cryptographic verification:
  - Prove an entry was included in the canonical ledger (inclusion proof)
  - Detect deletion, insertion, or modification in history
- Idempotent writes (client retries must not duplicate entries).

### Scale Targets

- Peak writes: 2,000 journal entries/s (≈12,000 postings/s).
- Retention: 7+ years; ~3B postings over time.
- Reads: 10k balance reads/s.

## Key Design Decisions

- One ledger committer per shard: the only code that assigns canonical order and produces signed blocks.
- Postgres does the hard correctness work: constraints + transactions enforce idempotency and double-entry.
- Deterministic hashing is versioned: every hashed/signed structure includes `format_version`.
- Canonicalization is fully specified:
  - `entry_canonical_bytes = JCS_JSON({format_version, ledger_id, client_request_id, occurred_at, external_ref, postings[], metadata})` (RFC 8785)
  - `postings[]` are sorted by `(account_id, currency, amount_minor, posting_ref)` and amounts are integers in minor units.
- Postgres is also the buffer: “accepted” means “durably written to the database”.

## Architecture

```mermaid
flowchart LR
  C[Clients] --> S["Ledger Service (API + Committer)"]
  S --> P[(Postgres)]
  S --> K[(KMS/HSM)]
  S --> A[(External Anchor / TSA)]

### Components

- `Ledger Service (API + Committer)`
  - Why it exists: it’s the only custom component; it owns request validation, idempotency contract, canonical ordering, and proof generation.
  - What it does:
    - API: accepts intents, returns deterministic responses for retries, serves reads/proofs/exports.
    - Committer loop: drains intents, assigns sequence numbers, writes entries+postings, builds blocks, stores proofs, signs block headers, and anchors asynchronously.

- `Postgres`
  - Why it exists: simplest place to enforce double-entry invariants and idempotency transactionally, and to persist an append-only history.
  - What it stores: intents, journal entries, postings, ledger head, blocks, per-entry proof paths, balances, and snapshots.

- `KMS/HSM`
  - Why it exists: signing keys stay out of the database and are auditable/rotatable.
  - What it does: signs block headers; the `signer_key_id` is stored with each block.

- `External Anchor / TSA`
  - Why it exists: provides tamper evidence outside the control plane for the block hash chain.
  - What it stores: an append-only receipt/reference for a given `block_hash`.

## Data Model (Conceptual)

- `entry_intents(ledger_id, client_request_id, request_hash, status, payload_json, received_at, committed_entry_id, error_code, error_text)`
- `ledger_heads(ledger_id, next_seq, head_block_hash)`
- `journal_entries(entry_id, ledger_id, client_request_id, occurred_at, committed_at, seq_no, format_version, entry_hash, block_id, leaf_index, external_ref, metadata_json)`
- `postings(entry_id, account_id, currency, amount_minor, ...)`
- `blocks(block_id, ledger_id, first_seq, last_seq, format_version, merkle_root, prev_block_hash, block_hash, signer_key_id, signature, anchored_at, anchor_ref)`
- `entry_proofs(entry_id, block_id, leaf_index, merkle_path_bytes)`
- `account_balances(ledger_id, account_id, currency, posted_balance_minor, updated_seq, updated_at)`
- `balance_snapshots(ledger_id, account_id, currency, as_of_time, posted_balance_minor)` (periodic; for “as-of T”)

Immutability is enforced by permissions (no `UPDATE/DELETE`) and by writing through stored procedures owned by a restricted role.

## Write Path

### Client-visible contract (idempotency + acceptance)

- Clients send `client_request_id` (idempotency key) with the full entry payload.
- The API writes one row to `entry_intents` with a unique constraint on `(ledger_id, client_request_id)`:
  - If the key is new: return `202 Accepted` with status `received`.
  - If the key exists and `request_hash` matches: return the existing state (`received` or `committed`) with the same identifiers.
  - If the key exists but `request_hash` differs: return `409 Conflict`.

This makes retries safe across process restarts, committer retries, and duplicate deliveries.

### Committer loop (single per ledger shard)

For each `ledger_id`, in a tight loop:

1. Claim a batch of intents:
   - `SELECT ... FOR UPDATE SKIP LOCKED` from `entry_intents` where `status = 'received'`.
2. In one DB transaction:
   - Lock `ledger_heads(ledger_id)` with `SELECT ... FOR UPDATE`.
   - Assign contiguous `seq_no` values.
   - Insert `journal_entries` + `postings` (append-only).
   - Enforce double-entry with a deferrable constraint (sum of postings per currency == 0).
   - Update `account_balances` for touched accounts (derived, rebuildable).
   - Commit exactly one block for the batch:
     - Compute `entry_hash = H(entry_canonical_bytes)` for each entry.
     - Build Merkle root over `entry_hash` leaves (seq order).
     - Store `blocks` row and `entry_proofs.merkle_path_bytes` for each entry.
     - Compute `block_hash = H(block_header_bytes)` and store `signature = Sign(block_hash)` via KMS/HSM.
     - Advance `ledger_heads.head_block_hash` and `ledger_heads.next_seq`.
   - Mark intents `committed` with the resulting `entry_id` (or `rejected` with a permanent error).

Block boundaries are explicit and boring:
- Each committer transaction produces one block; batch size is bounded by `max_entries` / `max_bytes`.

## Reads & Proofs

- Current balance: read from `account_balances` (O(1)).
- Balance as-of `T`: read `balance_snapshots` at/just before `T` + sum postings since snapshot (bounded work).
- Audit export: stream `journal_entries` by `seq_no` with their postings.
- Inclusion proof: fetch `blocks` + `entry_proofs` for the entry and verify:
  - `entry_hash` recomputes from `entry_canonical_bytes` (`format_version` included),
  - Merkle path leads to `merkle_root`,
  - `signature` verifies `block_hash`,
  - block hash chain links via `prev_block_hash`,
  - optional: `anchor_ref` matches an external receipt.

## Failure Modes

- Postgres down for 5 minutes
  - Behavior: API returns `503` (nothing is “accepted” without a durable intent write); committer pauses.
  - Recover: once Postgres returns, committer drains `entry_intents` and catches up.

- API can reach Postgres but committer can’t (or committer is down)
  - Behavior: intents accumulate in `entry_intents`; clients see `received` but not `committed`.
  - Recover: committer resumes and drains from `entry_intents`; API can apply backpressure (reject new intents) based on intent lag/size.

- Duplicate/reordered intent delivery
  - Behavior: harmless; uniqueness on `(ledger_id, client_request_id)` and deterministic retry responses prevent double effects.

- KMS/HSM unavailable
  - Behavior: commits pause (blocks must be signed to be verifiable); API can continue accepting intents if Postgres is healthy.
  - Recover: once KMS returns, committer resumes and drains from `entry_intents`.

- External anchoring outage
  - Behavior: blocks commit and proofs verify (signatures + hash chain); `anchored_at` lags.
  - Recover: retry anchoring from `blocks` where `anchored_at` is null (idempotent by `block_hash`).

- Operator mistake (unsafe migration, dropped partition, UPDATE granted)
  - Behavior: continuous verification detects hash/signature mismatches; treat as an incident.
  - Recover: freeze writes, preserve evidence, restore from immutable backups, and re-run verifier end-to-end.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Small-team operability (one service + Postgres) | Writes unavailable when Postgres is unavailable (no separate queue) |
| Strong invariants (DB-enforced) | Single-writer per ledger shard throughput ceiling |
| Simple proofs (block + Merkle + signature) | Some write latency from batching into blocks |
| Minimal moving parts | Proof data stored in Postgres increases storage and hot-set pressure |

## Operational Notes

- Lock down writes: committer role can `INSERT` via stored procedures; no `UPDATE/DELETE` on append-only tables.
- Partition `postings` and `journal_entries` by time to keep indexes/vacuum manageable.
- Run a verifier loop (in the same service) that recomputes block hashes/roots and checks signatures; alert on mismatch.
- Backups must be immutable and restore-tested; rebuilding balances/snapshots is supported from the journal.
