```markdown
---
title: "URL Shortener & Link Management"
category: "Foundational Infrastructure"
difficulty: "Hard"
tags: ["url-shortener", "edge-caching", "expiration", "abuse-prevention", "postgres", "redis"]
---

## Overview

This system creates and resolves short links with custom aliases, strict expiration, and strong abuse controls while keeping redirect latency globally low. The key insight is to treat redirects as a *cacheable content-serving problem* (edge-first, soft state) while treating link creation and policy enforcement as a *strongly consistent control plane* (single source of truth).

Elegance comes from one sharp boundary: **reads are optimized for speed and skew via bounded edge caching**, while **writes and safety decisions are centralized and auditable**. Instead of chasing perfect cache invalidation, we cap staleness with tight TTLs derived from expiration and use policy/versioning so “takedown” decisions propagate quickly without inventing new distributed consistency machinery.

## What Makes This Hard

Naive URL shorteners assume links are immutable and “never expire,” so they cache redirects aggressively and rarely revisit correctness. The trap here is that **expiration and abuse takedowns are correctness requirements**: a cached redirect that outlives an expiration window or a safety reversal becomes a real incident (security/compliance, not just freshness).

The second trap is that global low-latency reads tempt teams into globally replicated databases too early. That often shifts pain from latency to operational complexity. The winning move is exploiting workload skew: a tiny fraction of links drives most traffic, so **edge + regional caching beats global-write databases** for simplicity.

## Requirements

### Functional Requirements
- Create short links with:
  - Random codes and **custom aliases** (case rules, reserved words, normalization).
  - **Aggressive expiration** (minutes to days) and hard cutoff semantics.
  - Update/disable/delete (for owner actions and abuse takedowns).
- Resolve links with:
  - Global low-latency redirects.
  - Correct handling of expiration and takedowns (no “stale redirect” beyond bounded window).
- Abuse prevention:
  - Stop bulk creation, malicious destinations, phishing, malware, and scanning of the keyspace.
  - Provide fast takedown and appeal/audit trail.

### Scale Targets
- Redirects: **5B/day** (~58k QPS avg), **300k QPS peak** (flash events, bots).
- Link creates/updates: **2k QPS peak** (campaign launches), far smaller than reads.
- Active links: **100M**; metadata size ~300B/link ⇒ ~30GB raw, manageable in Postgres with partitioning.
- Latency: **p95 < 20ms** at edge for cache hits; **p99 < 150ms** for origin path.
- Correctness: expired/disabled links must stop redirecting within **≤ 5 minutes** globally (bounded by edge TTL cap), faster for high-severity abuse via purge.

## Key Design Decisions

- **Edge-cached redirects with bounded TTL**
  - Chose: CDN caches 301/302 responses with TTL = `min(expires_at - now, EDGE_MAX_TTL)` (e.g., 300s).
  - Rejected: long-lived edge caching + “perfect purge everywhere.”
  - Why: expiration/takedowns make perfect invalidation fragile; bounded TTL gives predictable worst-case staleness while still capturing skew.

- **Single authoritative store (Postgres) + regional read cache (Redis)**
  - Chose: Postgres as source of truth for link state/policy; Redis per region for fast origin hits.
  - Rejected: globally replicated primary database as the default solution.
  - Why: writes are modest; Postgres buys strong consistency, transactions, and auditability. Regional caches buy latency without multiplying write complexity.

- **Policy/versioned link records**
  - Chose: every link has `status`, `expires_at`, and `version`; updates bump version; caches store value + TTL.
  - Rejected: “delete from cache and hope” semantics.
  - Why: versioning makes correctness debuggable, enables safe cache refresh, and supports takedown workflows cleanly.

## Architecture

```mermaid
graph TD
  U[User/Browser] --> E[CDN Edge]
  E -->|miss/expired| R[Redirect API]
  R --> C[Redis (Regional)]
  R --> P[Postgres (Primary)]
  A[Admin/Create API] --> P
  A --> Q[Queue]
  Q --> S[Safety Scanner]
  S --> P
```

### Components

- **CDN Edge**
  - Serves cached redirects close to users.
  - Enforces coarse rate limits (IP, ASN, path) to blunt scanning and bot storms before origin.

- **Redirect API**
  - Small stateless service: validate code, fetch link state, enforce expiration/policy, return redirect or terminal response (410/404/451).
  - Only place that turns link state into HTTP caching headers (critical for correctness).

- **Redis (Regional)**
  - Read-through cache for link records to avoid Postgres on misses.
  - TTL aligned to `expires_at` (and short TTL for negative caching).

- **Postgres (Primary)**
  - Source of truth for link metadata, ownership, policy state, safety verdict, and audit log.
  - Partitioned by time (e.g., `created_at` month) and/or by `expires_at` for efficient expiration sweeps.

- **Admin/Create API**
  - Handles authentication, custom alias rules, quotas, and writes.
  - Performs synchronous “cheap checks” (syntax, allow/deny lists) and queues deep scans.

- **Queue + Safety Scanner**
  - Asynchronous URL analysis (malware/phishing feeds, content fetch, reputation).
  - Writes verdicts back to Postgres and triggers fast-path takedowns.

## Deep Dive: Correct Redirects Under Expiration + Takedowns

The hardest part is making redirects globally fast *and* correct when link state changes (expires, disabled, flagged). The trick is to design for bounded staleness instead of perfect freshness.

**Link record (authoritative):**
- `code` / `alias`
- `destination_url`
- `expires_at`
- `status` = `active | disabled | expired | blocked`
- `version` (monotonic)
- `safety_verdict` (+ reason, timestamps)

**Redirect path algorithm:**
1. **Edge cache hit**: serve redirect instantly.
2. **Edge miss**: call Redirect API.
3. Redirect API checks Redis:
   - If present, validate `status` and `expires_at > now`. If valid, respond.
   - If missing/expired, read Postgres, then populate Redis with:
     - TTL = `min(expires_at - now, REDIS_MAX_TTL)` (and a short TTL for `disabled/blocked` to avoid hot DB loops).
4. Response caching:
   - Set `Cache-Control`/`Surrogate-Control` with TTL = `min(expires_at - now, EDGE_MAX_TTL)`.
   - For terminal responses:
     - `410 Gone` for expired/deleted, cached briefly (e.g., 60s) to reduce repeat load.
     - `451 Unavailable` or interstitial for blocked, cached briefly but *not* long-lived.

**Why this works:**
- **Expiration correctness is enforced at every layer via TTL derived from `expires_at`.** The edge physically cannot cache beyond expiration.
- **Takedown correctness is bounded by `EDGE_MAX_TTL`** even if purge fails; worst-case stale redirect lasts minutes, not hours.
- For high-severity incidents, you still support **CDN purge by surrogate key** (best-effort accelerator), but you don’t depend on it for correctness.

The non-obvious lesson: for redirects, “cache invalidation is hard” becomes manageable when you turn it into “staleness is bounded and policy-driven,” with explicit worst-case guarantees.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Low-latency global reads via edge caching | Absolute immediate takedown everywhere (bounded by TTL cap) |
| Operational simplicity (Postgres + Redis) | Some extra engineering in cache headers/TTL discipline |
| Correct expiration semantics | Slightly lower edge hit ratio vs. very long TTLs |
| Strong auditability for abuse actions | More write-path rigor (versioning, state machine) |

## Failure Modes

- **CDN mis-caching (redirects outlive expiration)**
  - What happens: users keep redirecting to expired links.
  - Detect: metric “redirects past expires_at” sampled at origin; synthetic tests per POP.
  - Recover: enforce `EDGE_MAX_TTL`, add canary link that expires frequently, roll back CDN rules, emergency purge.

- **Cache stampede on hot link after TTL**
  - What happens: synchronized misses overload Redirect API/Redis/Postgres.
  - Detect: spikes in origin QPS and Redis miss rate; elevated p99.
  - Recover: single-flight in Redirect API, small jitter on TTLs, `stale-while-revalidate` at CDN, short-lived local in-process cache.

- **Abuse/scanning traffic (keyspace enumeration)**
  - What happens: massive 404 load, attempts to discover valid codes.
  - Detect: high 404 ratio by ASN/IP, high distinct-code rate, anomaly detection.
  - Recover: edge rate limits, bot challenges, negative caching (short TTL), and throttling by “distinct codes per minute.”

## What I'd Do Differently At...

- **10x scale:**
  - Add more POP coverage and tune `EDGE_MAX_TTL` down (e.g., 120s) while leaning harder on Redis.
  - Move heavy analytics off the redirect path entirely (log to stream).

- **100x scale:**
  - Split storage: keep Postgres for control plane + audit, move redirect-serving state into a globally replicated KV (managed) fed from the control plane.
  - Introduce dedicated abuse/brand protection workflows (multi-stage review, customer allowlists, stronger provenance).

## Operational Notes

- Treat TTL math as production-critical: `expires_at` must be in UTC, monotonic, and validated; reject links with absurdly long TTLs by policy.
- Monitor: edge hit ratio, origin QPS, Redis miss rate, Postgres read pressure, redirects-by-status (active/expired/blocked), and “takedown-to-effective” delay.
- Keep a tight incident playbook for safety reversals: block at origin immediately (status flip), then accelerate via Redis update + CDN purge for top offenders.
```