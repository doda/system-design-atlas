---
title: "Zero-Trust Access Proxy"
category: "Security & Access Control"
difficulty: "Hard"
tags: ["zero-trust", "iam", "proxy", "beyondcorp", "opa", "envoy"]
---

## Overview

A Zero-Trust Access Proxy replaces “network trust” (VPN = inside) with **request-level trust**: every request to every internal application is authenticated and authorized based on **identity**, **device posture**, and **policy**, regardless of source network.

At enterprise scale, the challenge is delivering **phishing-resistant** authentication, **least-privilege** authorization, and **continuous evaluation** without requiring changes to thousands of legacy apps and without turning the proxy into a high-latency, high-blast-radius dependency.

This design treats the proxy as an **L7 identity-aware reverse proxy**:
- Terminate TLS at the edge.
- Authenticate via OIDC/SAML (browser SSO, MFA, conditional access).
- Enforce authorization and posture policies (local evaluation on the hot path).
- Forward traffic to internal apps with a verifiable identity context (mTLS + signed headers/token).
- Emit durable audit logs asynchronously.

Comparable real-world systems include Google BeyondCorp / IAP, Cloudflare Access, and Zscaler Private Access.

## Requirements

### Functional Requirements
- Authenticate users against an enterprise IdP (OIDC preferred; SAML supported) with MFA and conditional access.
- Authorize **per request** using identity attributes (groups/roles), app metadata, request context, and device posture.
- Validate device posture (managed/enrolled, OS version, disk encryption, EDR running, jailbreak/root, compliance state, attestation freshness).
- Route authorized requests to the correct internal application over HTTPS; support multi-tenant and per-app config.
- Support step-up auth for sensitive apps and risk-based access (e.g., require fresh posture for “high risk” apps).
- Support non-browser clients (CLI/service access) via OAuth device code / client credentials + mTLS (where applicable).
- Provide admin APIs/UI for app onboarding, policy management, connector management, and audit access.
- Produce immutable audit trails for access decisions and admin actions with policy/version attribution.
- Provide safe rollout controls (deny-by-default, policy staging/canary, instant rollback, break-glass).

### Non-Functional Requirements (Concrete Targets)
- **Scale**
  - Users: 100k employees + 10k contractors (110k total).
  - Devices: 300k–1M registered devices (multi-device per user + shared devices).
  - Apps: ~5k internal web apps.
  - Traffic: peak 50k RPS global; typical sustained 5k–15k RPS global.
  - Audit volume: 5k RPS sustained × 86400 ≈ 432M events/day.
    - At 300–800 bytes/event (structured JSON + headers subset) ⇒ ~130–350 GB/day raw, before compression.
- **Latency**
  - Proxy overhead (excluding upstream app time): P50 < 10 ms, P99 < 50 ms.
  - Login flows (OIDC redirects + token exchange): P99 < 2 s (IdP dependent).
  - Config/policy propagation to all edges: P99 < 30 s after publish.
- **Availability**
  - Data plane (edge): 99.99% per region; global availability via multi-region active-active.
  - Control plane (admin/publish): 99.9%.
  - Graceful degradation when posture sources (MDM/EDR) degrade, without silent fail-open for high-risk apps.
- **Consistency**
  - Strong consistency for policy/version publish and key rotation metadata.
  - Eventual consistency acceptable for analytics/aggregations.
  - Posture decisions served with bounded staleness (TTL 60–300s) plus explicit `last_updated`.
- **Durability**
  - Policy/config RPO ≤ 5 minutes.
  - Audit: at-least-once ingestion; once accepted by the audit pipeline, **no loss** (RPO ≈ 0 for accepted events).

### Constraints & Assumptions
- Existing enterprise IdP (Okta/Azure AD/Ping) and device signal sources (Intune/Jamf + EDR).
- Primary scope: HTTPS web apps. Non-HTTP protocols (SSH/RDP) can be added later via protocol gateways.
- Many legacy apps cannot be modified; enforcement must work via reverse proxy + verified identity context.
- Compliance targets: SOC2 / ISO27001 (optionally HIPAA/PCI per tenant).

### Out of Scope (Initial Version)
- Full private network overlay / L3 VPN replacement.
- Inline DLP for content inspection (can integrate later).
- Full UEBA (user/entity behavior analytics) platform (export telemetry instead).

## Architecture

### High-Level Diagram

```mermaid
flowchart LR
  subgraph Internet["User Environment"]
    C[Browser / API Client]
    Agt[Device Agent<br/>(optional)]
  end

  subgraph EdgePlane["Data Plane (Multi-Region)"]
    LB[Global Anycast / Geo DNS<br/>+ L7 Load Balancer]
    EP[Edge Proxy Cluster<br/>(Envoy/NGINX)]
    PE[Local Policy Evaluator<br/>(OPA WASM)]
    Cache[Local Caches<br/>(JWKS, policy, posture, decisions)]
  end

  subgraph ControlPlane["Control Plane"]
    Admin[Admin UI / API]
    CP[Config & Policy Service<br/>(versioned publish)]
    Keys[KMS/HSM + Key Metadata]
    Bundles[Policy/Config Bundles<br/>(Object Store + CDN)]
  end

  subgraph Integrations["Enterprise & Signals"]
    IdP[Enterprise IdP<br/>(OIDC/SAML)]
    MDM[MDM (Intune/Jamf)]
    EDR[EDR (CrowdStrike/S1)]
    Dir[Directory / Groups<br/>(SCIM sync)]
  end

  subgraph PosturePlane["Posture System"]
    Ingest[Signal Ingestion<br/>(Kafka/PubSub)]
    Compute[Decision Compute<br/>(Streams)]
    PStore[(Device Inventory DB)]
    PCache[(Posture Cache: Redis)]
  end

  subgraph Apps["Private Apps"]
    App1[Internal App(s)]
    AppGW[Upstream mTLS / Identity Gateway<br/>(optional)]
  end

  subgraph AuditPlane["Audit & Telemetry"]
    Q[Audit Queue<br/>(Kafka/PubSub)]
    Raw[(Object Storage: immutable)]
    Hot[(Search/OLAP: OpenSearch/ClickHouse)]
    SIEM[SIEM Export (Splunk/etc.)]
  end

  C --> LB --> EP
  Agt -. posture attest .-> EP

  EP <--> IdP
  EP --> Cache --> PE
  EP --> PCache
  EP --> AppGW --> App1

  Admin --> CP --> Bundles
  CP --> Keys
  Bundles --> EP

  MDM --> Ingest
  EDR --> Ingest
  Ingest --> Compute --> PStore --> PCache
  Dir --> CP

  EP --> Q --> Raw
  Q --> Hot --> SIEM
```

### Trust Boundaries and Threat Model (What This Must Defend Against)
- Stolen passwords/session cookies (phishing, malware) ⇒ require MFA, phishing-resistant options, short-lived tokens, step-up.
- Header spoofing to apps ⇒ **strip inbound identity headers**; use **mTLS** and/or a **signed upstream identity token**.
- Stale posture decisions ⇒ include `last_updated` and enforce freshness for high-risk apps.
- Dependency outages (IdP/MDM/EDR/Kafka) ⇒ design hot path to be locally evaluable and degrade predictably.
- Policy mistakes ⇒ staged rollout, canary, automated checks, and instant rollback.

## Components

### 1) Edge Proxy (Data Plane)
**Responsibilities**
- TLS termination, routing, and per-request enforcement.
- Browser SSO redirects and session validation.
- Local JWT verification (IdP tokens and/or proxy-issued access tokens).
- Policy evaluation (allow/deny/step-up) and enforcement.
- Upstream identity propagation to apps.
- Rate limiting and abuse protection (per user/app/IP).

**Key Design Choices**
- **Keep the hot path local**: verify tokens locally; evaluate policy locally (OPA WASM); use caches for posture and policy bundles.
- **No synchronous calls to MDM/EDR on requests**: posture is precomputed and served from cache.
- **Asynchronous audit**: emit events to a queue with bounded buffering and backpressure protection.

**Identity Propagation to Upstreams (Prevent Spoofing)**
- Always remove inbound headers like `X-User`, `X-Groups`, `X-Email`, etc.
- Prefer one of:
  1) **mTLS to upstream** + headers (apps trust only mTLS-authenticated proxy), or
  2) **Signed upstream identity token** (JWT) in `X-Access-Token` that the app verifies via proxy JWKS.
- Include `tenant_id`, `user_id`, `groups/entitlements`, `device_id`, `posture_state`, `policy_version`, `issued_at`, and short `exp`.

**Technology**
- Envoy (recommended) with External AuthZ + OPA WASM, or NGINX with auth_request + OPA sidecar.
- mTLS upstream using internal CA (SPIFFE/SPIRE optional).

---

### 2) Identity & Session Service (Auth Broker)
**Responsibilities**
- OIDC Authorization Code + PKCE for browsers.
- SAML-to-OIDC brokering where needed.
- Session management (cookie-based), step-up orchestration, logout.
- Mint short-lived proxy-issued access tokens for the edge hot path (optional but common).

**Key Design Choices**
- Keep IdP off the request hot path: authenticate at session creation/refresh; afterwards rely on short-lived proxy-issued tokens validated locally.
- Store only minimal session metadata server-side; keep cookies `Secure`, `HttpOnly`, `SameSite=Lax/Strict` as appropriate, and use `__Host-` prefix where possible.

**State**
- Redis (clustered) for session records, nonce/state, and step-up markers.
- KMS/HSM for signing keys and rotation.

---

### 3) Policy System (Authoring, Versioning, Distribution)
**Responsibilities**
- Policy authoring (RBAC + ABAC), review/approval workflow.
- Versioned publishing with canary cohorts and instant rollback.
- Bundle distribution to all edge regions.

**Key Design Choices**
- **Policy as versioned artifacts**: publish immutable bundles with `policy_version`.
- **Push-based distribution**: xDS/gRPC or CDN-backed bundle fetch with long-poll/Etag; target propagation P99 < 30s.
- **Deterministic evaluation inputs**: decisions are explainable and auditable (reason codes + version).

**Technology**
- OPA bundles (Rego) or Cedar/OPA hybrid depending on org maturity.
- Postgres for source-of-truth metadata; object storage + CDN for bundle blobs.

---

### 4) Device Posture System
**Responsibilities**
- Ingest device signals from MDM/EDR/attestation sources.
- Compute a normalized posture decision per device.
- Serve posture decisions quickly to edge (cache-first).

**Key Design Choices**
- Split pipeline into:
  - **Ingestion** (third-party variability, retries, webhooks),
  - **Computation** (normalize + evaluate posture rules),
  - **Serving** (Redis + edge cache).
- Include posture metadata: `compliant`, `reasons[]`, `last_updated`, and `source_freshness`.
- Support risk-based requirements: low-risk apps may accept stale posture; high-risk apps require freshness (e.g., `last_updated <= 2m`).

**Technology**
- Kafka/PubSub for ingestion, stream processor (Kafka Streams/Flink), Postgres for inventory, Redis for posture cache.

---

### 5) Audit & Telemetry Pipeline
**Responsibilities**
- Durable, tamper-resistant audit trail for:
  - Access decisions (allow/deny/step-up) with reasons.
  - Admin actions (policy publish/rollback, app onboarding, key rotation).
- Queryable hot store for investigations and reporting.
- Export to SIEM.

**Key Design Choices**
- At-least-once delivery with idempotent consumers.
- Store immutable raw logs in object storage (retention policy, legal hold).
- Index only a hot window (e.g., 7–30 days) for cost control; query older data from object store with batch jobs.

**Technology**
- Kafka/PubSub, object storage (S3/GCS), OpenSearch/ClickHouse, SIEM connectors.

## Data Model

### Core Entities (Control Plane Postgres)
- `tenants`
  - `tenant_id (uuid, pk)`, `name`, `status`, `created_at`
- `apps`
  - `app_id (uuid, pk)`, `tenant_id (fk)`, `name`, `hostname_patterns[]`, `upstream_url`, `risk_level (low|medium|high)`, `owner_team`, `created_at`
- `policies`
  - `policy_id (uuid, pk)`, `tenant_id (fk)`, `name`, `created_at`, `created_by`
- `policy_versions`
  - `policy_version_id (uuid, pk)`, `policy_id (fk)`, `version (int)`, `bundle_uri`, `status (draft|canary|active|rolled_back)`, `published_at`, `published_by`
- `policy_rollouts`
  - `policy_version_id (fk)`, `cohort_type (percent|group|user)`, `cohort_selector`, `created_at`
- `apps_policy_bindings`
  - `app_id (fk)`, `policy_id (fk)`, `priority (int)`, `created_at`
- `admin_audit`
  - `event_id`, `tenant_id`, `actor`, `action`, `resource_type`, `resource_id`, `policy_version_id?`, `created_at`, `metadata (jsonb)`

### Device Inventory (Posture Postgres)
- `devices`
  - `device_id (uuid, pk)`, `tenant_id`, `primary_user_id`, `platform`, `os_version`, `managed (bool)`, `encryption (bool)`, `edr (bool)`, `last_seen_at`
- `device_signals`
  - `device_id`, `tenant_id`, `source (mdm|edr|attestation)`, `signal (jsonb)`, `observed_at`, `ingested_at`

### Hot Caches (Redis)
- `posture:{tenant_id}:{device_id}` → `{compliant, reasons[], last_updated, ttl_seconds, posture_epoch}`
- `session:{session_id}` → `{tenant_id, user_id, device_id?, amr, last_auth_at, step_up_state}`
- `revoked_sessions:{tenant_id}` → bloom/filter or set (bounded) for high-risk revocations
- `policy_active:{tenant_id}:{app_id}` → `{policy_version_id, etag}`

### Audit Event Schema (Immutable)
`AuditEvent` (JSON/Avro/Protobuf)
- `event_id`, `timestamp`, `tenant_id`, `request_id/trace_id`
- `user`: `{user_id, email?, groups_hash, authn_context (amr/acr)}`
- `device`: `{device_id?, posture (compliant/stale/unknown), last_updated?}`
- `app`: `{app_id, hostname, risk_level}`
- `decision`: `{result (allow|deny|step_up), reason_codes[], policy_version_id}`
- `request_meta`: `{method, path, source_ip, user_agent, region}`

## API Design

### User-Facing (Proxy Behavior)
Requests arrive on the app’s hostname (e.g., `https://billing.internal.example.com/`).

**Browser Flow**
- Unauthenticated: redirect to IdP (OIDC Auth Code + PKCE).
- Authenticated: validate session, fetch posture from cache, evaluate policy, forward or deny.

**Non-Browser/API Clients**
- Prefer `Authorization: Bearer <token>` with short-lived tokens minted by the proxy (or directly from IdP if compatible).
- Optional mTLS client auth for high-risk administrative APIs.

**Common Errors**
- `302` redirect to IdP (browser, unauthenticated).
- `401` unauthenticated (API clients).
- `403` unauthorized / non-compliant / policy-denied.
- `429` rate-limited.
- `503` dependency degraded (only when policy requires fail-closed and no cached answer exists).

### Control Plane (Admin API)
- `POST /v1/apps`
  - Request: `{name, hostname_patterns, upstream_url, risk_level, owner_team}`
  - Response: `{app_id, ...}`
  - Idempotency: `Idempotency-Key`
- `POST /v1/policies`
  - Request: `{name, type, source}` (e.g., Rego bundle or higher-level DSL)
  - Response: `{policy_id}`
- `POST /v1/policies/{policy_id}/versions`
  - Request: `{bundle, change_summary}`
  - Response: `{policy_version_id, version}`
- `POST /v1/policies/{policy_id}/publish`
  - Request: `{policy_version_id, rollout: {mode: "canary"|"full", percent?}}`
  - Response: `{policy_version_id, status}`
- `POST /v1/policies/{policy_id}/rollback`
  - Request: `{to_policy_version_id}`
  - Response: `{active_policy_version_id}`
- `GET /v1/audit?app_id=&user_id=&from=&to=`
  - Response: paginated; async export for large ranges

### Posture API (Internal)
- `POST /v1/device_signals`
  - Request: `{tenant_id, device_id, source, signal, observed_at}`
  - Response: `202 Accepted`
  - Idempotency: dedupe on `(tenant_id, device_id, source, observed_at, signal_hash)`
- `GET /v1/posture/{tenant_id}/{device_id}`
  - Response: `{compliant, reasons[], last_updated, ttl_seconds, posture_epoch}`

## Scaling & Performance

### Hot Path Cost Model (Why This Meets Latency Targets)
For an authorized request, the edge does:
1) Session/JWT validation (local signature verify; JWKS cached).
2) Posture lookup (edge cache hit typical; fallback to Redis).
3) Policy evaluation (OPA WASM; inputs are small, deterministic).
4) Optional decision cache (10–60s) for high-QPS endpoints.

This keeps P99 overhead achievable (<50ms) because there are **no synchronous third-party calls** (IdP/MDM/EDR) on the request path.

### Bottlenecks and Mitigations
- **JWT verification CPU**: use efficient crypto libs, reuse parsed JWKs, keep tokens compact, and avoid huge group lists (use entitlements hash when possible).
- **Policy evaluation**: compile to WASM, keep policies simple and bounded, and enforce evaluation timeouts.
- **Redis posture/session**: shard by `tenant_id` and key hash; use local edge caching to reduce QPS.
- **Audit throughput**: batch/async publish, partition topics by tenant/time, and separate raw retention from indexing.

### Horizontal Scaling
- **Edge proxy**
  - Stateless, autoscale per region.
  - Multi-region active-active with geo routing; failover on health.
  - Connection draining and progressive delivery for upgrades.
- **Control plane**
  - Reads via replicas; writes via leader per tenant (or global leader) to preserve publish ordering.
  - Bundle blobs served via CDN/object store to offload the control plane.
- **Posture**
  - Stream processing partitions by `(tenant_id, device_id)`; independent scaling from the edge.

### Caching Strategy (With Bounded Risk)
- **JWKS**: cache 5–15 min; prefetch on `kid` miss; support overlapping keys during rotation.
- **Policy bundles**: cache active version; fetch by ETag; pin cohorts for canary.
- **Posture**: cache 60–300s; include `last_updated`; enforce freshness for high-risk apps.
- **Decision cache**: cache 10–60s keyed by `(tenant, app, user_entitlements_hash, device_posture_epoch, method, path_template)`; invalidate via `policy_version_id` and `posture_epoch`.

## Trade-offs & Alternatives

### Trade-offs (At Least Three)
1) **Local JWT validation vs token introspection**
   - Chosen: local validation for latency and availability.
   - Cost: revocation is not instantaneous.
   - Mitigations: short TTLs (5–10 min), step-up for high-risk actions, targeted revocation lists for critical accounts, and event-driven session revocation where supported.

2) **Local policy evaluation (OPA WASM) vs centralized PDP calls**
   - Chosen: local evaluation to avoid an always-on per-request dependency.
   - Cost: policy distribution and debugging are harder.
   - Mitigations: strict versioned bundles, canary rollouts, decision reason codes, and audit events that record inputs/versions.

3) **Fail-closed posture for high-risk apps vs availability**
   - Chosen: high-risk apps default to fail-closed when posture is unknown/stale beyond threshold.
   - Cost: users may be blocked during signal outages.
   - Mitigations: per-app risk modes, grace windows for known-good devices, step-up auth fallback, and clear UX explaining remediation.

4) **mTLS-to-upstream enforcement vs header-only propagation**
   - Chosen: mTLS (or signed upstream token) to prevent header spoofing.
   - Cost: operational overhead (cert issuance/rotation, app integration).
   - Mitigations: optional “identity gateway” in front of legacy apps and phased rollout by app criticality.

### Alternative Approaches
- **Agent-based ZTNA overlay (private tunnel/mesh)**
  - Pros: supports arbitrary TCP protocols; strong device binding.
  - Cons: heavier client footprint; complex routing and support burden.
- **Service mesh-only enforcement**
  - Pros: excellent east-west identity and policy within clusters.
  - Cons: does not solve end-user ingress authentication/device posture without an edge layer.
- **Central gateway + per-request directory/posture lookups**
  - Pros: simpler logic, always fresh.
  - Cons: tail latency and availability suffer; third-party systems become hard dependencies.

## Failure Modes & Mitigations

### Failure Scenarios (At Least Three)
1) **IdP outage or degraded performance**
   - Impact: new logins and step-up flows fail; existing sessions continue until session expiry.
   - Mitigations: keep IdP off hot path; allow existing sessions to function with proxy-issued short-lived tokens; provide operational “step-up disabled” mode for low-risk apps; run multi-IdP only if required (complex).

2) **Posture signals delayed/outage (MDM/EDR)**
   - Impact: posture becomes stale; high-risk apps may deny access.
   - Mitigations: edge uses cached posture with explicit max staleness; risk-based freshness requirements; remediation UX; step-up fallback when posture is stale but previously compliant.

3) **Bad policy publish (over-deny or unintended allow)**
   - Impact: widespread outage or security exposure.
   - Mitigations: linting/unit tests for policies, shadow evaluation on sampled traffic, canary cohorts, automatic rollback on deny spike/SLO burn, and break-glass policy stored as a signed local bundle.

4) **Key rotation bug / clock skew**
   - Impact: mass auth failures (invalid signatures/exp), or acceptance of expired tokens.
   - Mitigations: overlapping keys, strict NTP monitoring, leeway bounds (small), emergency rollback to prior keyset, and alarms on `kid` miss/verify failure rates.

5) **Audit pipeline backpressure (Kafka/PubSub incident)**
   - Impact: risk of blocking hot path if synchronous; risk of audit loss if unbuffered.
   - Mitigations: asynchronous publish with bounded local buffers; shed non-critical telemetry before audit; circuit breakers; queue durability SLOs; alerting on buffer utilization and consumer lag.

### Disaster Recovery
- **Targets**
  - Regional RTO: 30 minutes (control plane); data plane failover should be automatic within minutes.
  - Policy/config RPO: ≤ 5 minutes (Postgres PITR + replicated bundles).
  - Audit: once accepted by the queue, no loss; replicate raw storage cross-region.
- **Mechanisms**
  - Postgres PITR + automated restore runbooks; periodic DR drills.
  - Multi-region object storage replication for bundles and raw audit.
  - Synthetic canaries per region and per critical app.

## Operations

### SLOs and Alerts
- **Edge SLOs**
  - Availability: 99.99% per region (requests not failing due to proxy).
  - Overhead latency: P99 < 50ms (exclude upstream time; measure at edge).
  - Error budgets with burn-rate alerts (fast/slow).
- **Key Metrics**
  - RPS, P50/P95/P99, 401/403/429/5xx, upstream connect errors, cache hit ratios, OPA eval time, JWT verify failures, posture staleness distribution.
  - Auth flow success rate and time-to-login (P95/P99).
  - Audit queue publish rate, buffer usage, consumer lag, indexing delays.
- **Security Signals**
  - Deny spikes by reason code, anomalous geo/IP, replay-like patterns, privilege escalations, policy change frequency, break-glass usage.

### Deployment and Change Management
- Edge: canary/blue-green with connection draining; rollback in minutes.
- Control plane: standard canary; schema migrations with backward compatibility.
- Policy: draft → automated tests → canary cohorts → full publish; require approvals for high-risk apps.
- Keys: scheduled rotation with overlap; emergency rotation runbooks; continuous verification of JWKS propagation.

### Access Governance
- Admin actions protected by strong authn (phishing-resistant) and least privilege.
- Periodic access reviews for app owners and policy authors.
- Break-glass accounts: tightly controlled, monitored, and audited; short-lived enablement.

### Data Retention and Privacy
- Audit retention: e.g., 1 year raw immutable logs (configurable), 30 days indexed hot store.
- Minimize sensitive fields in logs; hash or tokenize where possible; encrypt at rest and in transit.
- Tenant isolation: separate encryption keys and access controls per tenant.

## References & Further Reading
- BeyondCorp: A New Approach to Enterprise Security (Google)
- NIST SP 800-207: Zero Trust Architecture
- OAuth 2.0 / OpenID Connect (Authorization Code + PKCE)
- Envoy External Authorization (ext_authz) documentation
- Open Policy Agent (OPA), Rego, and OPA bundles
- Cloudflare Access / Zscaler Private Access architecture overviews