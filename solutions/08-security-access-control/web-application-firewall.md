---
generation_time_seconds: 890
title: "Web Application Firewall (WAF)"
category: "Security & Access Control"
difficulty: "Hard"
tags: [security, edge, waf, http, ddos, rules, observability]
---

## Overview

This system is an **edge WAF** that sits in front of web applications and blocks SQL injection, XSS, and malicious payloads **at line speed** without becoming the bottleneck.

The WAF is a **deterministic, precompiled filter** that runs inside a mature edge proxy (no dynamic policy code in the request path). Everything else—rule authoring, validation, safe rollout/rollback, and telemetry—lives in a small control plane.

## What Makes This Hard

1. **Adversarial cost:** attackers try to turn parsing and matching into CPU/memory bombs (giant headers, chunked bodies, encoding tricks, regex abuse).
2. **False positives:** blocking real users is worse than missing a niche signature; rules must ship with safety gates.
3. **Global blast radius:** one bad update can break every property faster than any application deploy.

## Requirements

### Functional Requirements
- Detect and mitigate common injection classes (SQLi, XSS, command injection, path traversal) across URL, headers, cookies, query params, and common body formats.
- Support actions: `ALLOW`, `BLOCK`, `CHALLENGE`, `LOG_ONLY`.
- Support per-route policy (e.g., stricter on `/login`) without per-request network calls.
- Provide shadow mode and explainability: stable rule IDs + matched locations.
- Provide safe rollout: shadow → canary POPs → wider rollout, plus instant rollback.
- Continue serving safely on control-plane outage: POPs run on last-known-good rules indefinitely.
- Ensure observability cannot add latency: bounded queues + drop-on-overload.

### Scale Targets
- **Traffic:** 1M requests/sec aggregate; 50k RPS burst per POP.
- **Latency budget:** +2 ms p99 added by WAF at the edge.
- **Payload limits:** up to 32 KB headers, 1 MB body (route-configurable hard caps).
- **Ruleset size:** 10k–50k signatures + heuristics compiled to bounded primitives.

## Key Design Decisions

- **Choose: WAF as an Envoy/Nginx filter with precompiled rules**
  - Rejected: custom proxy stack or per-request scripting
  - Why: keep protocol handling boring and keep evaluation bounded.

- **Choose: signed, versioned rule artifacts pulled by POPs**
  - Rejected: push-based “distributor” dependencies in the hot path
  - Why: POPs keep last-known-good, upgrades are explicit, rollback is instant.

- **Choose: bounded parsing and matching with runtime circuit breakers**
  - Rejected: “full inspection” by buffering and best-effort timeouts
  - Why: adversaries control input; the WAF must control worst-case work.

- **Choose: stateless challenges**
  - Rejected: global state stores or per-request lookups for challenges
  - Why: challenges must not introduce a new availability dependency.

## Architecture

```mermaid
flowchart LR
  C[Client] --> E[Edge Proxy<br/>+ WAF Filter]
  E --> O[Origin App]
  E --> L[Event Stream]
  CP[Rule Control Plane] --> E
  L --> CP

### Components

- **Edge Proxy**
  - Why it exists: TLS termination, strict HTTP parsing, and hard caps are the cheapest place to stop junk traffic.
  - Simplified: use a mature proxy (Envoy/Nginx) for HTTP/2/3 edge cases and smuggling defenses.

- **WAF Filter (Data Plane)**
  - Why it exists: the only place decisions must be made per request with a strict latency budget.
  - Properties:
    - deterministic evaluation (no network calls)
    - strict caps (decoded bytes, token counts, match work)
    - verifies rule artifact signatures and hot-swaps by version
    - challenges are stateless (signed short-TTL token cookie)

- **Origin App**
  - Why it exists: the system being protected; WAF is additive.

- **Rule Control Plane**
  - Why it exists: rules are code; they need validation, provenance, staged rollout, and rollback.
  - Responsibilities:
    - compile rules into bounded match primitives and reject unsafe constructs
    - run pre-deploy cost gates (worst-case corpus microbench + size caps)
    - sign and publish immutable rule artifacts by version
    - orchestrate rollout state (shadow/canary/global) and expose rollback by pinning a prior version

- **Event Stream**
  - Why it exists: tuning and incident response without coupling telemetry to request latency.
  - Properties:
    - edge has a bounded queue; events drop when full
    - allows are sampled; blocks/challenges are prioritized
    - local counters/metrics always emitted even if detailed events drop

## Deep Dive: Line-Speed Detection Without Regex DoS

### 1) Canonicalization first, with a clear contract
The data plane normalizes inputs so matching is predictable:
- Percent-decoding with recursion limits and strict invalid-encoding rejection
- Path normalization (`/a/../b` → `/b`) with strict dot-segment handling
- Header/cookie parsing with bounded field counts and strict duplicate-header policy
- UTF-8 validation; invalid encodings are immediate block signals

Shadow mode is used to introduce stricter normalization safely (observe before enforce).

### 2) Compile rules into bounded-time primitives
- Multi-pattern scan for fixed substrings (Aho–Corasick class)
- Safe regex only (RE2-class; capped by inspected length and match work)
- Small scoring only where needed (weak signals add up; strong signals act alone)

### 3) Streaming body inspection with hard caps
- Only inspect bodies on routes that accept user input, up to a route byte budget.
- Parse incrementally for `application/x-www-form-urlencoded` and `application/json`; scan decoded values.
- Stop inspecting after the budget and continue forwarding the stream.

### 4) Bounded execution enforcement and safe rollouts
Every request has a fixed work budget:
- per-phase byte limits (decoded URL/headers/cookies/body)
- per-rule match work caps and a global per-request time budget
- circuit breaker: when budgets are exceeded, skip remaining expensive phases (e.g., body inspection) and prefer `CHALLENGE`/`LOG_ONLY` over unpredictable work

Every rollout is gated:
- artifacts are immutable, signed, and verified in the POP before activation
- POPs only advance to new versions when explicitly allowed by rollout state; otherwise they keep the pinned version
- rollback is a version pin; POPs revert on next poll without needing new artifacts

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Predictable latency under attack | Deep inspection of huge/streaming bodies |
| Offline-safe edge operation | “Live” per-request policy decisions |
| Simple global safety (version pin rollback) | Fine-grained per-POP manual tweaking |
| Stateless challenges | Provider-style CAPTCHA integrations as a dependency |

## Failure Modes

- **Bad ruleset blocks legitimate traffic**
  - Detect: block/challenge rate deltas on critical routes; origin error deltas.
  - Recover: rollback by version pin; emergency local downgrade to `LOG_ONLY` for affected routes.

- **Control plane down for minutes**
  - What happens: rollouts pause; POPs keep last-known-good indefinitely.
  - Recover: restore control plane; no edge impact required.

- **Network partition between POPs and control plane**
  - What happens: POPs keep pinned version; upgrades freeze.
  - Recover: connectivity returns; rollouts resume from known version state.

- **Event stream slow or down**
  - What happens: edge drops events once queues fill; request latency unaffected.
  - Recover: telemetry returns; counters show the gap; no edge change required.

- **CPU saturation at POP during attack**
  - Detect: rising evaluation time, queue depth, p99.
  - Recover: circuit breakers disable body inspection first; stricter limits; shift to `CHALLENGE` on high-risk routes; scale out proxy capacity.

## What We Removed

- Dedicated **Rule Distributor**: distribution is pull-by-version from the control plane’s published artifacts; POPs cache and pin.
- Separate **Analytics/Tuning** service: tuning loop runs off the event stream and feeds back into control plane rule updates.
- Any **per-request external dependency** (DB lookups, state stores, third-party challenge checks): the edge stays deterministic and offline-safe.
- Unbounded matching constructs: only bounded primitives and safe regex.

## Operational Notes

- Rule artifacts are signed; POPs verify on load. Key rotation is supported; on key compromise, POPs stop accepting new artifacts and stay pinned to last-known-good until keys are replaced.
- Telemetry is best-effort by design: bounded memory, drop-on-overload, and counters always on.
- Shadow mode is required for rule and normalization changes; promotion to `BLOCK` requires canary health gates and a tested rollback path.
