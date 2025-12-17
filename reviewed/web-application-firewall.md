---
title: "Web Application Firewall (WAF)"
category: "Security & Access Control"
difficulty: "Hard"
tags: ["waf", "edge-security", "appsec", "ddos-mitigation", "rate-limiting", "observability"]
---

## Overview

A Web Application Firewall (WAF) is an edge security layer that inspects HTTP(S) traffic to detect and mitigate application-layer attacks (e.g., SQL injection, XSS, path traversal, SSRF, protocol evasion, malformed payloads) before requests reach origin services.

The core systems challenge is adversarial: attackers actively craft traffic to maximize false negatives (bypass) and false positives (denial), while also attempting to exhaust CPU, memory, connection state, and logging pipelines. A production WAF must deliver **high detection quality** under **tight latency and compute budgets**, at **global scale**, with **safe configuration and rollouts**.

A robust design separates:
- **Data plane (edge)**: a fast, deterministic, mostly stateless request evaluation pipeline with strict resource bounds and predictable worst-case behavior.
- **Control plane (central)**: strongly-consistent policy authoring, validation, staged rollout, audit, and rollback, with eventual propagation to edge PoPs.

---

## Requirements

### Goals
- Block and/or challenge common web attacks on inbound HTTP(S) while preserving availability and low latency.
- Support multi-tenant isolation: per-tenant policies, per-hostname/per-route overrides, and per-tenant observability and retention.
- Make changes safe: validate policies before deployment, roll out gradually, and roll back instantly.
- Provide operational visibility: actionable metrics, searchable events, and audited configuration history.

### Non-Goals
- Replacing L3/L4 DDoS scrubbing (the WAF integrates with it but does not attempt to solve volumetric attacks alone).
- Detecting unknown zero-days via heavy ML inference inline at line rate (optional offline analytics are fine).
- Full payload inspection for arbitrarily large bodies or streaming uploads (bounded inspection is required for predictability).

### Functional Requirements
- Inspect inbound HTTP(S) requests to detect and mitigate:
  - SQLi, XSS, template injection, command injection, path traversal, SSRF patterns
  - protocol evasion and ambiguous parsing (multi-encoding, mixed path separators, header smuggling attempts)
  - malformed requests and known malicious user agents/bots (where appropriate)
- Support policy capabilities per tenant:
  - managed rule sets (e.g., OWASP CRS-like)
  - custom rules (declarative rule language)
  - allow/deny lists (IP/CIDR, ASN, Geo), per-route overrides (e.g., `/login`, `/checkout`)
  - per-route parsing settings (JSON/form/XML), per-route body inspection limits
- Actions: `allow`, `block` (403), `redirect` (3xx), `rate_limit`, `challenge` (CAPTCHA/device proof/JS challenge), `log_only`.
- Normalization/canonicalization prior to inspection:
  - URL normalization (decode + re-encode rules), path dot-segment resolution, case handling where appropriate
  - header canonicalization, duplicate header policies, content-type aware parsing
  - multi-encoding detection (bounded)
- Logging and forensics:
  - request metadata, matched rule IDs, decision/action, scoring details
  - sampled and redacted snippets (optional tier), payload hashes, correlation IDs
- Safe rollout:
  - dry-run/monitor mode, canaries, staged rollout steps, and instant rollback
  - per-tenant “break-glass” bypass controls with audited access
- Control plane APIs/UI:
  - policy CRUD, rule testing/simulation, rollout orchestration, audit history
- Managed signatures:
  - continuously updated without downtime (immutable signed bundles; PoPs hot-swap)

### Non-Functional Requirements (Targets)
- **Scale**
  - Tenants: ~1,000 (with skew: top 10 tenants may represent >50% traffic)
  - Global peak: up to **1,000,000 HTTP requests/sec** (bursty; uneven by PoP)
  - Aggregate ingress: **100–400 Gbps** across PoPs (mix of small API calls and larger web requests)
- **Latency (added overhead at edge)**
  - Typical requests: **P50 ≤ 0.5 ms**, **P99 ≤ 2 ms**
  - Degraded/heavy paths (large bodies, complex routes): **P99 ≤ 5 ms** with explicit limits and graceful degradation
  - **Hard budget**: per-request inspection bounded by **bytes inspected** and **instruction/time budget** (e.g., ~200–500 µs CPU for typical requests on modern cores)
- **Availability**
  - Data plane: **99.99%**
  - Control plane (authoring/rollouts): **99.9%**, with PoPs continuing on “last known good”
- **Consistency**
  - Control plane: strong consistency for policy versioning/audit (single source of truth)
  - Edge propagation: eventual consistency with a target **<60s** to reach most PoPs; explicit versioning and observability of skew
- **Durability**
  - Policy/audit: RPO ~0 (multi-AZ database + WAL archival)
  - Security events: best-effort under overload with bounded loss (tiered), but critical counters/metrics should remain accurate
- **Security & Compliance**
  - Encryption in transit (mTLS service-to-service), encryption at rest
  - Data minimization, redaction, tenant-configurable retention (e.g., 7–90 days), access controls and audit logs

### Constraints & Assumptions
- Traffic reaches nearest healthy PoP via Anycast or geo-DNS.
- TLS is terminated at the edge (or at an L7 proxy that exposes decrypted HTTP to the WAF filter).
- Worst-case attacker behavior is assumed (e.g., intentionally adversarial payloads and request floods).
- The WAF must remain stable and predictable under malformed input; it must avoid ambiguity in parsing and normalization.

---

## Architecture

### High-Level Architecture

```mermaid
flowchart TB
  %% Entry
  C[Client] --> R[Anycast / Geo Routing]
  R --> POP[Edge PoP]

  %% Data plane
  subgraph DP[Data Plane (Per PoP)]
    direction TB
    L7[L7 Proxy / Gateway<br/>Envoy / NGINX / HAProxy] --> WAF[WAF Filter / Engine]
    WAF --> ORI[Origin Services]
    WAF --> RL[Rate Limiter<br/>(local + regional)]
    WAF --> TEL[Telemetry Agent]
  end

  POP --> L7

  %% Control plane
  subgraph CP[Control Plane (Central)]
    direction TB
    API[Admin UI / API] --> POL[Policy Service]
    POL --> DB[(Postgres<br/>Policy + Audit)]
    POL --> BUILD[Bundle Build + Validation Workers]
    BUILD --> OBJ[(Object Storage<br/>Signed Bundles)]
    POL --> MAN[Managed Rules Feed Ingest]
    MAN --> BUILD
    KMS[KMS / HSM] --> BUILD
  end

  %% Distribution
  OBJ -->|HTTPS pull + ETag| POP
  DB --> POL

  %% Telemetry
  subgraph OBS[Telemetry & Analytics]
    direction TB
    BUS[Event Stream<br/>Kafka/PubSub] --> HOT[(Hot Store<br/>ClickHouse/Elastic)]
    BUS --> ARCH[(Archive<br/>Object Storage)]
    HOT --> DASH[Dashboards / Search]
  end

  TEL --> BUS
```

### Key Architectural Principles
- **Deterministic, bounded evaluation** in the data plane to prevent attacker-controlled worst-case CPU/memory (no unbounded regex backtracking; strict parse and scan limits).
- **Immutable, signed policy bundles** with atomic hot-swap at PoPs (RCU-style pointer swap), enabling instant rollback.
- **Fail-safe posture configurable per tenant**:
  - *Fail-open* (default for availability): if WAF cannot evaluate safely, allow and emit a high-severity signal.
  - *Fail-closed* (high-security tenants/routes): block on evaluation failure (with explicit guardrails and careful rollout).
- **Asynchronous telemetry** with backpressure and loss controls so logging never blocks the request path.

---

## Components

### Edge PoP: Routing + L7 Proxy
**Responsibilities**
- TLS termination, HTTP parsing, connection management (HTTP/2/HTTP/3 where applicable)
- Enforce coarse limits before WAF (headers/body size, request rate caps, connection limits)
- Forward allowed traffic to origin; generate synthetic responses for block/challenge

**Key Decisions**
- Prefer a mature proxy (Envoy/NGINX/HAProxy) to avoid bespoke parsing bugs and reduce request smuggling risk.
- Apply strict parsing mode and normalize ambiguous inputs early (reject invalid transfer-encoding combinations, enforce header rules).

**Typical Limits (illustrative defaults)**
- Max header bytes: 32 KB; max header count: 100; max request line: 8 KB
- Max body bytes accepted by proxy: configurable (e.g., 10–50 MB), but **WAF inspection** is capped separately
- Per-connection and per-IP rate caps at L7 to reduce amplification of expensive paths

### WAF Engine (Data Plane)
**Responsibilities**
- Normalize/canonicalize request components
- Evaluate rules/signatures and scoring
- Execute actions (allow/block/challenge/rate_limit/log_only)
- Emit structured events and metrics

**Pipeline (bounded and short-circuiting)**
1. **Parse & feature extraction**: method, host, path, query, headers, content-type, sizes, TLS/client hints.
2. **Canonicalization (bounded)**:
   - normalize path (`.`/`..`, separator normalization), percent-decoding with recursion limits
   - header normalization (canonical names, duplicate header policy), cookie parsing limits
3. **Fast gates** (O(1)/O(n) over bounded inputs):
   - allow/deny (IP/CIDR, ASN, geo), known bad reputation lists
   - method/path constraints and per-route limits
4. **Signature matching**:
   - multi-pattern scanning on normalized buffers using deterministic engines (Aho–Corasick/Hyperscan)
   - safe regex (RE2) only, with caps on match count and inspected bytes
5. **Structured parsing (optional, bounded)**:
   - JSON/form/XML parsing with streaming and truncation; extract key/value tokens
6. **Decision & response**: apply action, attach correlation IDs, set decision headers (optional internal), enforce rate limits/challenges.
7. **Async telemetry**: enqueue event; on backpressure, drop low-value fields first (never block the request).

**Technology Choices**
- Implementation: Rust/C++ (performance + memory safety); Envoy filter (native or WASM) or NGINX module depending on platform
- Pattern matching: Hyperscan for multi-regex where available; RE2 for safe regex; Aho–Corasick for keyword sets
- Data structures: radix trie for CIDRs, compact tries for path prefixes, cuckoo filters/bloom filters for hot deny sets (as an optimization)

**Multi-Tenancy**
- Policy bundle selection by SNI/Host + route matching (prefix tree)
- Hard per-tenant budgets (CPU/bytes inspected) and optional tenant isolation pools for “heavy” policies

### Rate Limiter & Bot/Abuse Controls
**Responsibilities**
- Per-tenant and per-route limits (e.g., `/login` stricter than `/assets`)
- Detect credential stuffing, scraping, and abusive automation
- Coordinate “challenge” escalation

**Design**
- Token bucket for steady-state rate limits; sliding window or leaky bucket for burst sensitivity
- **Local-first decisions** at PoP for latency; optional regional/global aggregation for stricter global limits
- Identify keys by configurable fingerprints: IP, IP+UA hash, session cookie, device token, API key, or login identifier (with privacy constraints)

**Backends**
- Local in-memory counters for hot path; Redis/KeyDB (regional) for shared enforcement
- Optional approximate structures (Count-Min Sketch) for high-cardinality keys

**Degradation**
- If shared limiter backend is unavailable: keep enforcing local limits; prefer `challenge` over `block` for anomaly signals; emit alerts

### Control Plane: Policy, Validation, Rollouts
**Responsibilities**
- Policy authoring, simulation/testing, versioning, approval workflows (optional)
- Bundle build/compilation and signing
- Rollout orchestration and rollback
- Managed rule ingestion and publishing

**Key Decisions**
- Policies are **immutable versions**: rollouts promote a version; they do not mutate live state.
- Validation is “shift-left”:
  - compile rule AST to an IR, enforce limits, reject unsafe constructs
  - precompile regex (RE2), generate automata where applicable
  - run a test corpus (unit samples + tenant-provided samples), compute cost estimates and match statistics
- Signed artifacts:
  - bundles signed with Ed25519/ECDSA; PoPs ship with trusted public keys
  - key rotation supported via overlapping trust sets

**Bundle Distribution**
- PoPs **pull** bundles from object storage/CDN using ETag; verify signature; load into memory; atomic swap
- PoPs keep **N recent versions** for rollback (e.g., last 5) and a “last known good” pointer

### Telemetry & Analytics
**Responsibilities**
- Durable event stream for detections, investigations, and tuning
- Low-latency metrics for rollouts and SLOs
- Searchable forensics with tenant isolation and retention

**Data Minimization**
- Default events store metadata and rule IDs; sensitive fields redacted/hashes by default
- Payload snippets are:
  - disabled by default, tenant-gated, redacted, size-capped (e.g., 256–1024 bytes), and sampled
  - protected by stricter access controls and auditing

---

## Data Model

### Storage Schema (Logical)

**Policy and audit (Postgres)**
- `tenants(id, name, plan, created_at)`
- `users(id, tenant_id, email, role, created_at)` (or integrate with external IdP)
- `policies(id, tenant_id, name, created_at)`
- `policy_versions(id, policy_id, version, mode, status, created_at, created_by, changelog)`
  - `mode ∈ {enforce, monitor}`
  - `status ∈ {draft, validating, validated, rejected, deprecated}`
- `policy_bindings(id, tenant_id, hostname, path_prefix, policy_version_id, priority, created_at)`
- `rollouts(id, tenant_id, policy_version_id, state, canary_percent, steps, step_minutes, started_at, finished_at)`
- `audit_log(id, tenant_id, actor, action, target_type, target_id, diff_json, created_at)`

**Bundles (Object Storage)**
- `bundles/{tenant_id}/{policy_id}/{version}.tar.zst`
  - `manifest.json` (limits, routes, rule IDs, compiled matcher metadata)
  - `matchers.bin` (compiled automata, keyword tables)
  - `responses.json` (block/challenge templates)
  - `signature.sig` + `checksums.txt`

**Security events (Hot store + archive)**
- `waf_events(tenant_id, ts, request_id, trace_id, client_ip_hash, method, host, path, route_id, action, status_code, matched_rule_ids, score, pop, origin, user_agent_hash, body_truncated, sampling_rate, redaction_level)`
- Indexes:
  - `(tenant_id, ts)`
  - `(tenant_id, action, ts)`
  - `(tenant_id, matched_rule_ids, ts)`
  - `(tenant_id, client_ip_hash, ts)`

### Rule Representation (Conceptual)
A portable rule model that compiles to deterministic matchers:

```json
{
  "id": "942100",
  "name": "SQLi keywords in args",
  "phase": "request",
  "when": {
    "any": [
      { "field": "query", "match": { "type": "multi_pattern", "set": "sqli_keywords_v3" } },
      { "field": "body.tokens", "match": { "type": "re2", "pattern": "(?i)\\bunion\\s+select\\b" } }
    ]
  },
  "action": { "type": "block", "status": 403 },
  "tags": ["sqli", "owasp-crs-compatible"],
  "severity": "high"
}
```

---

## API

### Authn/Authz
- Auth: OIDC (recommended) with JWTs; service-to-service mTLS.
- Authorization: RBAC per tenant (e.g., `viewer`, `editor`, `admin`) and scoped API keys for automation.
- All mutating actions are audited; sensitive read endpoints require elevated roles.

### Policy Management (REST)
- `POST /v1/tenants/{tenantId}/policies`
  - Request: `{ "name": "prod-waf" }`
  - Response: `{ "policyId": "pol_...", "createdAt": "..." }`
- `POST /v1/policies/{policyId}/versions`
  - Request: `{ "baseVersion": 12, "mode": "monitor", "rules": [...], "limits": {...}, "changelog": "Tighten login rules" }`
  - Response: `{ "versionId": "pv_...", "version": 13, "status": "validating" }`
  - Errors:
    - `400` invalid schema
    - `409` version conflict
    - `422` rejected (e.g., `RULE_REGEX_TOO_COMPLEX`, `INSPECTION_LIMIT_TOO_HIGH`)
- `GET /v1/policies/{policyId}/versions/{version}`
  - Response includes compiled-cost estimates, rule counts, and validation outcomes.
- `POST /v1/policy-versions/{versionId}/rollouts`
  - Request: `{ "canaryPercent": 5, "steps": [5, 25, 100], "stepMinutes": 10, "autoHalt": { "p99AddedLatencyMs": 2, "blockRateIncreasePct": 200 } }`
  - Response: `{ "rolloutId": "ro_...", "state": "running" }`
- `POST /v1/rollouts/{rolloutId}/rollback`
  - Response: `{ "state": "rolled_back", "activeVersion": 12 }`

**Idempotency**
- Support `Idempotency-Key` on create endpoints; store `(tenantId, key) -> response` for 24h.

### Rule Testing / Simulation
- `POST /v1/policies/{policyId}/simulate`
  - Request: `{ "version": 13, "request": { "method": "POST", "url": "https://shop.example.com/login", "headers": {...}, "bodyBase64": "..." } }`
  - Response: `{ "action": "challenge", "matchedRuleIds": ["913101"], "score": 7, "explanations": ["..."], "bodyTruncated": true }`

### Event Query (Read API)
- `GET /v1/tenants/{tenantId}/events?from=...&to=...&action=block&ruleId=942100`
  - Response: paginated results; sensitive fields redacted by default.
- Pagination: cursor-based (`nextCursor`) to avoid deep offsets.
- Rate limits: tenant-scoped; heavy queries routed to a separate analytics tier.

### Error Format
- Use JSON Problem Details with stable `code` fields:
  - `RULE_REGEX_TOO_COMPLEX`, `BUNDLE_SIGNATURE_INVALID`, `ROLLOUT_IN_PROGRESS`, `PERMISSION_DENIED`

---

## Scaling & Performance

### Capacity Planning (Back-of-the-envelope)
At **1M RPS** global peak, assume:
- Average request headers+query inspected: ~2–8 KB
- A bounded body inspection window: e.g., first **32 KB** for JSON/form (route-configurable)
- Per-request CPU budget: **~200–500 µs** typical
This implies a design that:
- stays mostly in L1/L2-friendly data structures
- avoids allocations on the hot path (use arenas/pools)
- ensures rule evaluation is linear over bounded buffers

### Key Bottlenecks and Mitigations
- **Regex/signature CPU**
  - Use deterministic engines (Hyperscan/AC) and safe regex (RE2 only)
  - Cap inspected bytes, match counts, and per-phase time/steps
- **Body parsing overhead**
  - Stream parsing with early exits; truncate tokens after N bytes/tokens
  - Per-route parsing strategy (do not parse XML for routes that never accept it)
- **State pressure from hot attackers**
  - Local rate limiting first; approximate counters for high cardinality
  - Protect shared backends (Redis) with circuit breakers and isolation
- **Telemetry overhead**
  - Async-only; drop payload snippets first; aggregate to counters under pressure

### Horizontal Scaling
- **PoPs**: stateless scale-out; autoscale on CPU, queue depth, p99 added latency, and connection count.
- **Control plane**: stateless API tier; Postgres HA; validation/build workers scale independently.
- **Telemetry**: partition streams by tenant/time; independent scaling for consumers; separate hot store from archive.

### Caching & Invalidation
- **PoP bundle cache** keyed by `(tenantId, policyVersion)`; keep last N + last-known-good.
- **Control plane caches** for policy reads and validation results; ETag distribution for bundles.
- **Invalidation** is by version (immutable artifacts); “latest” pointers are updated atomically with audit entries.

---

## Trade-offs

### Key Trade-offs Made
- **Bounded inspection vs full inspection**
  - Gain: predictable performance and resilience against CPU exhaustion
  - Cost: attacks embedded beyond the inspection window may evade detection
  - Mitigation: per-route tuning, anomaly scoring, and origin-side validation as defense-in-depth
- **Eventual edge propagation vs globally strong consistency**
  - Gain: higher availability and simpler edge operations
  - Cost: short windows of version skew across PoPs
  - Mitigation: explicit versioning, skew dashboards, and canary metrics before broad rollout
- **Challenge escalation vs immediate blocking for anomaly detections**
  - Gain: reduced false-positive blast radius and better UX recovery
  - Cost: added friction for some legitimate users
  - Mitigation: route-based exceptions, risk-based step-up, and tight monitoring during rollout
- **Fail-open default vs fail-closed security posture**
  - Gain: availability during partial failures
  - Cost: reduced protection during evaluation failures
  - Mitigation: tenant-configurable posture, strict alerting, and isolating failure causes quickly

### Alternatives
- **Origin-side WAF only**
  - Higher origin load and latency; origin becomes the DoS target; less global capacity
- **Pure ML inline detection**
  - Hard to audit/explain; higher operational complexity; costly inference at line rate
- **Inline deep inspection for all bytes**
  - Unbounded work; fragile under malformed encodings and large uploads; poor tail latency behavior

---

## Failure Modes

### Failure Scenarios and Mitigations
- **Bad rule update causes high false positives**
  - Detection: canary shows block/challenge rate spike; origin success drops; tenant alerts
  - Mitigation: staged rollout + auto-halt; one-click rollback; route-level bypass; monitor-only mode
- **Pathological inputs attempt CPU exhaustion (e.g., adversarial regex, oversized fields, encoding bombs)**
  - Detection: per-route p99 added latency spikes; rule-ID hotspots; watchdog timeouts
  - Mitigation: RE2-only, cost checks during validation, strict byte/time budgets, early exits, reject ambiguous encodings
- **Telemetry pipeline outage/backpressure**
  - Detection: stream lag, agent queue growth, sink errors
  - Mitigation: async buffers with caps; degrade to metrics-only; sample aggressively; drop non-critical fields first
- **PoP loses control-plane/object-storage connectivity**
  - Detection: last-update age alarms; skew dashboards
  - Mitigation: continue with cached last-known-good; exponential backoff; multi-origin bundle sources (CDN + regional fallback)
- **Bundle integrity failure (signature verification fails)**
  - Detection: verification errors at PoPs; sudden stall in rollout progress
  - Mitigation: never activate invalid bundles; keep serving prior version; alert; rotate keys if needed; investigate supply chain
- **Regional/PoP outage**
  - Detection: health checks, error rates, withdrawal events
  - Mitigation: Anycast/geo failover; capacity buffers; automated traffic steering; fast binary rollback

### Disaster Recovery (Control Plane)
- **RTO/RPO**: control plane RTO ~1 hour, RPO ~0 (multi-AZ Postgres + WAL archiving); telemetry RTO ~4 hours, RPO minutes (buffered).
- **Backups**: daily full + continuous WAL; immutable bundles replicated multi-region; periodic restore tests.
- **Failover**: promote standby DB; redeploy API tier; PoPs continue on cached bundles during control-plane failover.

---

## Operations

### SLOs and Alerts (Examples)
- Data plane SLOs:
  - Added latency: p99 ≤ 2 ms (typical) / ≤ 5 ms (heavy paths)
  - Availability: 99.99%
  - Error rate: 5xx from edge components ≤ 0.01%
- Rollout safety:
  - Auto-halt if block/challenge rate increases > X% vs baseline on canary routes
  - Auto-halt if origin success rate drops or p99 added latency regresses beyond threshold
- Operational alerts:
  - Config skew: >10% PoPs on old version after 10 minutes
  - Signature verification failures > 0
  - Rate limiter backend error rate > 1% for 5 minutes

### Deployment Strategy
- Data plane: PoP-by-PoP canary; blue/green at PoP; keep bundle format backward compatible.
- Bundles: atomic activation only after full verification and load; keep N previous versions resident for rollback.
- Control plane: standard multi-AZ deploy with rolling updates; validation/build workers separate from API tier.

### Security Operations
- Access control: least privilege RBAC; audited “break-glass” actions; separate duties for managed rule publishing.
- Key management: KMS/HSM for signing keys; rotation procedures; PoP trust bundle updates via standard deploy.
- Incident response:
  - false positive incident: flip to monitor-only for impacted binding, rollback, and root-cause via rule hit analytics
  - bypass incident: publish emergency managed rule update with accelerated rollout and enhanced telemetry sampling

---

## References & Further Reading
- OWASP Core Rule Set (CRS): https://coreruleset.org/
- ModSecurity (WAF engine concepts): https://github.com/owasp-modsecurity/ModSecurity
- Google RE2 (safe regex): https://github.com/google/re2
- Hyperscan (high-performance multi-regex): https://github.com/intel/hyperscan
- Envoy Proxy (filters, ext_authz, overload manager): https://www.envoyproxy.io/
- AWS WAF (managed rules and deployment model): https://docs.aws.amazon.com/waf/
- Cloudflare WAF and edge security patterns: https://developers.cloudflare.com/waf/
