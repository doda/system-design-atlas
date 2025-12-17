---
title: "Secure File Sharing"
category: "Security & Access Control"
difficulty: "Hard"
tags: ["security", "dlp", "file-sharing", "audit-logging", "kms", "abuse-prevention"]
---

## Overview

Secure file sharing for sensitive documents is deceptively hard because the “happy path” (upload → share link → download) is easy, while the real requirements live in abuse prevention, data leakage controls, and provable auditing. A production-grade system must support expiring links that can be revoked effectively immediately, enforce fine-grained access policies, scan content for malware and sensitive data (DLP) before allowing external access, and apply dynamic watermarks that tie a leaked copy back to a specific viewer and time.

A good mental model is a split between:

- **Data plane (immutable blobs)**: originals in object storage with strong durability and encryption.
- **Control plane (strongly-consistent metadata + policy)**: links, permissions, scan status, and revocation state in a transactional datastore.
- **Derivation plane (just-in-time renditions)**: watermarked exports (and optionally view-only tiles) produced only after a policy decision.

Downloads are not “direct object reads”; they are *policy decision → short-lived authorization → controlled delivery*, which is the core enforcement point for security, abuse controls, and auditing.

---

## Requirements

### Functional Requirements

- Upload documents (PDF, Office, images) via resumable upload; validate type/size and compute checksums.
- Create share links with expiration, optional password and/or OTP, and optional recipient allowlist (email/domain).
- Enforce malware scanning and DLP scanning with policy actions (allow, redact, quarantine, block) before any external sharing.
- Download shared documents with per-request dynamic watermarking (viewer identity, timestamp, link ID, org) applied to the delivered content.
- Support link lifecycle: view stats, revoke, extend/shorten expiration, rotate link token, enforce max-download limits.
- Maintain immutable audit logs suitable for compliance (who shared what, who accessed what, policy decisions, admin actions).
- Admin controls: org policies (max TTL, external sharing enablement, auth requirements, watermark templates, DLP rules, residency).
- Abuse controls: rate limits, token brute-force detection, anomaly detection (high-volume exfiltration, suspicious IP/ASN, geo velocity).

### Non-Functional Requirements (Targets)

#### Scale (example sizing)

- **Uploads**: 5M/day, avg 5 MB → ~25 TB/day ingest (peak ~5K upload QPS).
- **Downloads**: 20M/day (average ~230 QPS), peak **authorize** QPS up to ~15K.
- **Rendered exports** (watermarked PDFs): assume 10–20% of downloads require a server-side rendered export → size for **1–3K render QPS** peak (rendering is the dominant cost).
- **Audit events**: 50–150M/day (upload lifecycle, link lifecycle, auth decisions, downloads, admin actions).

#### Latency

- Create link P99: **≤ 150 ms**.
- Authorization (token resolve + policy) P99: **≤ 80 ms**.
- Download start P99:
  - **View (HTML/tiles/stream)** TTFB: **≤ 250 ms** once authorized.
  - **Rendered export** first byte P99: **≤ 400 ms** (with streaming), with full completion dependent on document size/format.

#### Availability & Durability

- **Authorization + revoke enforcement**: **99.99%**.
- **Upload + DLP pipelines + rendering**: **99.9%** (degrades to “deny external access” rather than “allow”).
- **Object durability**: 11 9s (cloud object store).
- **Metadata**: RPO **≤ 5 minutes**, RTO **≤ 30 minutes** (regional failover).
- **Audit log**: immutable/WORM retention per policy (e.g., 1–7 years), with *at-least-once ingestion* and deduplication.

### Consistency Model

- **Strongly consistent**: link revoke/rotate/expire checks, permission checks, org policy gates, “approved for external access” decisions.
- **Eventual**: analytics counters, search indexing, non-blocking dashboards, long-running DLP finding enrichment.

### Constraints & Assumptions

- Multi-tenant SaaS with enterprise orgs; some require data residency (region pinning) and tenant-level encryption controls (BYOK optional).
- Zero trust: share links and client metadata are untrusted input; server-side enforcement only.
- Managed services preferred (object store, queue/stream, KMS, CDN/WAF).
- Compliance targets: SOC 2 Type II; optional HIPAA/PCI depending on customer and data types.

---

## Architecture

### High-Level Diagram

```mermaid
flowchart TB
  C[Client Apps] --> E[CDN + WAF]
  E --> G[API Gateway]

  subgraph ControlPlane[Control Plane]
    G --> A[AuthN/AuthZ]
    G --> S[Share Service]
    S --> R[(Redis Cache)]
    S --> M[(Metadata DB)]
    S --> P[Policy Engine]
    S --> L[Audit Log Writer]
  end

  subgraph DataPlane[Data Plane]
    C -->|pre-signed PUT| O[(Object Storage - Originals)]
    S -->|signed GET (internal)| O
    S -->|optional| OR[(Object Storage - Renditions)]
  end

  subgraph Pipelines[Async Pipelines]
    S --> Q[(Queue/Stream)]
    Q --> AV[Malware Scan Workers]
    Q --> DLP[DLP Workers]
    AV --> M
    DLP --> M
  end

  subgraph Delivery[Delivery / Derivation]
    S --> W[Watermark/Render Service]
    W --> OR
  end
```

### Key Ideas

- **Direct-to-object-store uploads** reduce API load, but uploads are not shareable externally until scans/policy allow it.
- **Authorization is stateful** (metadata DB is the source of truth) to make revocation and policy updates effective quickly.
- **Rendering is isolated** (sandboxed) because document parsing is a common exploitation vector.
- **Fail closed for external access**: if policy, scanning, or audit components are unhealthy, external downloads are denied rather than allowed.

---

## Components

### CDN + WAF + API Gateway

**Responsibilities**
- TLS termination, bot/WAF protections, request normalization, rate limiting, request ID injection, geo/IP/ASN signals.

**Critical controls**
- Per-IP and per-ASN rate limits for token endpoints.
- Challenge/JS proof-of-work/CAPTCHA escalation on suspicious patterns.
- Strict request size limits and content-type validation for API endpoints (uploads are direct-to-object-store).

### AuthN/AuthZ Service

**Responsibilities**
- Authenticate users (OIDC/SAML SSO), issue access tokens, enforce org membership, device/session policy, step-up auth.
- Provide identity claims used in watermarking and audit (e.g., user ID, email, org ID).

**Notes**
- Keep identity resolution separate from share-link authorization to support both authenticated and “external recipient” flows.
- Use step-up auth for sensitive actions (e.g., creating public links, rotating tokens, disabling DLP gates).

### Share Service (Control Plane)

**Responsibilities**
- Document metadata lifecycle, link creation/revocation/rotation, authorization decisions, orchestrate delivery (view/export).
- Emit audit events for every decision (allow/deny/error) with correlation IDs.

**Design choices**
- **Token handling**: generate ≥ 192-bit random tokens; store only a **keyed hash** (e.g., `HMAC-SHA256(pepper, token)`) to prevent offline guessing if DB leaks.
- **Two-stage download**: `authorize` (strong checks) → short-lived `download_token` (60s) bound to claims (link_id, doc_id, org_id, viewer identity, IP/ASN risk tier).
- **Revocation**: enforce from primary metadata store; caches must be short TTL and/or invalidated on revoke.

### Metadata Store

**Recommended**: Postgres (or Spanner/CockroachDB if global strong consistency is required).

**Why Postgres works**
- Strong transactional semantics for link lifecycle and revocation.
- Partial indexes and table partitioning for high-ingest event tables.
- Clear operational model with PITR and replicas.

**Scaling posture**
- Keep hot authorization queries on primary (or a strongly consistent read path).
- Partition/time-bound large append-only tables (events), and ship to a data lake for long-term retention/analytics.

### Redis Cache

**Use cases**
- Short TTL caches for token-hash → link metadata (seconds).
- Distributed rate-limiting counters (with edge as first line of defense).
- Idempotency-key de-duplication records.

**Rule**
- Cache is an optimization only; authorization correctness cannot depend on Redis availability.

### Object Storage (Originals + Renditions)

**Responsibilities**
- Store immutable originals with versioning and lifecycle policies.
- Store optional renditions (watermarked exports, thumbnails) with short TTL and encryption.

**Security**
- Envelope encryption with KMS-managed keys; consider **per-tenant keys** and optional BYOK.
- Separate prefixes/buckets by region and (optionally) tenant class to satisfy residency and blast-radius goals.
- Deny public ACLs; block all public access; restrict access via IAM and VPC endpoints/private links.

### Malware + DLP Pipeline

**Stages**
1. **Malware scan** (fast gating): quarantine if suspicious; never allow external access while pending/failed.
2. **DLP classification**: extract text/metadata, detect sensitive types (PII/PHI/secrets), and produce findings.
3. **Policy decision**: apply org policy to findings (allow/redact/quarantine/block), record a decision version.

**Why split “findings” vs “decision”**
- Findings are facts; decisions change when policy changes. Re-evaluating decisions becomes safe and auditable.

### Watermark/Render Service

**Responsibilities**
- Produce a watermarked export (PDF/image) per viewer/request when policy requires “hard” watermarking.
- Optionally support “view mode” delivery (page tiles) to reduce expensive full-document exports.

**Isolation**
- Run in hardened sandboxes (gVisor/Firecracker) with strict CPU/memory/time limits and no outbound network.
- Treat file parsing libraries as untrusted surfaces; keep them patched and observably constrained.

**Performance note**
- Rendering is the most expensive path; design so not every “view” requires a full export render.

### Audit Log System (Immutable)

**Goals**
- Tamper-evident, append-only, queryable by compliance teams.
- Supports retention, legal hold, and export.

**Implementation**
- Write events to a durable stream (Kafka/PubSub/Kinesis) and to WORM storage (e.g., S3 Object Lock) via a controlled pipeline.
- Use event IDs for deduplication; accept at-least-once delivery.

---

## Data Model

### Core Tables (OLTP)

**documents**
- `document_id` (UUID, PK)
- `org_id` (UUID, indexed)
- `owner_user_id` (UUID, indexed)
- `object_key` (text)
- `size_bytes` (bigint)
- `sha256` (bytea, indexed)
- `mime_type` (text)
- `created_at` (timestamptz, indexed)
- `scan_state` (enum: UPLOADING, PENDING_AV, PENDING_DLP, APPROVED, QUARANTINED, BLOCKED)
- `scan_decision_version` (int)
- `retention_policy` (jsonb)

**share_links**
- `link_id` (UUID, PK)
- `org_id` (UUID, indexed)
- `document_id` (UUID, indexed)
- `token_hash` (bytea, unique)            <!-- HMAC(token) -->
- `created_by_user_id` (UUID)
- `expires_at` (timestamptz, indexed)
- `revoked_at` (timestamptz, nullable, indexed)
- `require_auth` (bool)
- `require_otp` (bool)
- `password_hash` (bytea, nullable)       <!-- Argon2id/scrypt -->
- `allowed_recipients` (jsonb, nullable)  <!-- emails/domains -->
- `max_downloads` (int, nullable)
- `download_count` (int, default 0)
- `watermark_policy` (jsonb)
- `created_at` (timestamptz)

**download_tokens** (short-lived, optional persistence)
- `token_id` (UUID, PK)
- `link_id` (UUID, indexed)
- `document_id` (UUID, indexed)
- `org_id` (UUID, indexed)
- `viewer_subject` (text)                 <!-- user_id or external recipient handle -->
- `expires_at` (timestamptz, indexed)
- `issued_at` (timestamptz)

**dlp_findings**
- `document_id` (UUID, indexed)
- `finding_type` (text)
- `count` (int)
- `sample_hashes` (jsonb)
- `scanner_version` (text)
- `created_at` (timestamptz)

**scan_decisions**
- `document_id` (UUID, indexed)
- `decision_version` (int)
- `result` (enum: APPROVED, QUARANTINED, BLOCKED, REDACT_REQUIRED)
- `reason_codes` (jsonb)
- `decided_at` (timestamptz)
- `decided_by` (enum: POLICY_ENGINE, ADMIN_OVERRIDE)
- `signature` (bytea, nullable)           <!-- if decisions are signed by a separate service -->

### Eventing and Audit

**access_events (hot window only; partitioned by day/week)**
- `event_id` (UUID, PK)
- `org_id` (UUID, indexed)
- `link_id` (UUID, indexed)
- `document_id` (UUID, indexed)
- `actor_type` (enum: USER, EXTERNAL, ANON)
- `actor_id` (text)                       <!-- stable subject id; avoid raw email if possible -->
- `ip` (inet)
- `user_agent` (text)
- `action` (enum: LINK_CREATED, LINK_REVOKED, LINK_ROTATED, AUTHORIZED, DOWNLOAD_STARTED, DOWNLOAD_COMPLETED, DENIED, SCAN_DECIDED, ADMIN_POLICY_CHANGED)
- `result` (enum: ALLOW, DENY, ERROR)
- `reason_code` (text, nullable)
- `created_at` (timestamptz, indexed)

**Long-term retention**
- Ship events to immutable storage/data lake; keep OLTP retention short (e.g., 7–30 days) to control DB growth.

---

## API

### Upload

`POST /v1/uploads:init`

Request:
```json
{
  "org_id": "uuid",
  "filename": "q4-report.pdf",
  "mime_type": "application/pdf",
  "size_bytes": 5234123
}
```

Response:
```json
{
  "upload_id": "uuid",
  "document_id": "uuid",
  "parts": [
    { "part_number": 1, "put_url": "https://..." }
  ],
  "expires_in_seconds": 900
}
```

`POST /v1/uploads:complete`

Request:
```json
{
  "upload_id": "uuid",
  "sha256": "base64-encoded-bytes",
  "parts": [
    { "part_number": 1, "etag": "\"...\"" }
  ]
}
```

Response:
```json
{
  "document_id": "uuid",
  "scan_state": "PENDING_AV"
}
```

Notes
- Require `Idempotency-Key` for mutations; scope by `(org_id, idempotency_key)` with TTL (e.g., 24h).
- Enforce server-side expected size/type; do not trust client-provided MIME alone (sniff magic bytes post-upload when feasible).

### Create Share Link

`POST /v1/documents/{document_id}/share-links`

Request:
```json
{
  "expires_at": "2025-12-31T00:00:00Z",
  "require_auth": true,
  "require_otp": false,
  "allowed_recipients": ["alice@acme.com", "acme.com"],
  "password": null,
  "max_downloads": 25,
  "watermark_policy": {
    "mode": "DYNAMIC",
    "fields": ["viewer", "timestamp", "link_id", "org"],
    "placement": "diagonal",
    "opacity": 0.18
  }
}
```

Response:
```json
{
  "link_id": "uuid",
  "share_url": "https://files.example.com/s/BASE64URLTOKEN",
  "expires_at": "2025-12-31T00:00:00Z"
}
```

Errors
- `412 PRECONDITION_FAILED`: document not yet externally shareable (e.g., `scan_state != APPROVED`).
- `409 CONFLICT`: org policy forbids requested sharing mode (e.g., external sharing disabled).
- `429 TOO_MANY_REQUESTS`: abuse/rate-limit.

### Authorize and Download

`POST /v1/share-links/{token}/authorize`

Request:
```json
{
  "password": null,
  "otp": null,
  "client_fingerprint": "opaque-client-signal"
}
```

Response:
```json
{
  "download_token": "opaque-short-lived-token",
  "expires_in_seconds": 60,
  "delivery_modes": ["VIEW", "EXPORT"]
}
```

`GET /v1/downloads/{download_token}?mode=EXPORT`

Response
- `200` streamed bytes with:
  - `Content-Disposition: attachment; filename="q4-report.pdf"`
  - `Cache-Control: no-store`
  - `Content-Security-Policy: sandbox` (for in-browser viewers, if applicable)

Errors
- `403 FORBIDDEN`: policy deny (revoked, not allowed recipient, auth required, scan not approved, etc.).
- `410 GONE`: expired token/link.
- `423 LOCKED`: quarantined (e.g., malware suspected).
- `429 TOO_MANY_REQUESTS`: abuse controls/backpressure.

### Revoke / Rotate

`POST /v1/share-links/{link_id}:revoke` → `204`

`POST /v1/share-links/{link_id}:rotate`

Response:
```json
{
  "link_id": "uuid",
  "share_url": "https://files.example.com/s/NEWBASE64URLTOKEN"
}
```

### Error Format (consistent)

```json
{
  "code": "LINK_EXPIRED",
  "message": "Share link expired",
  "request_id": "req_123",
  "details": {
    "link_id": "uuid"
  }
}
```

---

## Scaling

### Hot Paths and Mitigations

- **Token resolution + policy checks**
  - Keep the DB query tight (index on `token_hash`, `expires_at`, `revoked_at`).
  - Redis cache for `token_hash → link_id/document_id/policy` with TTL 5–30s, plus invalidation on revoke/rotate.

- **Rendering**
  - Prefer “VIEW” mode (page tiles/stream) for most interactions; reserve full “EXPORT” renders for explicit downloads or policy needs.
  - Autoscale render workers on queue depth; enforce hard timeouts and per-org quotas.
  - Cache short-lived renditions keyed by `(document_id, link_id, viewer_subject, watermark_template_version)` for a few minutes in encrypted object storage.

- **Scan backlog**
  - Separate malware gating from DLP; malware can run quickly and block early.
  - Priority lanes: documents with pending share link creation or pending downloads get higher scan priority.
  - Operational transparency: expose scan status and ETA to users; allow admin override with explicit audit.

### Storage and Data Growth

- **Documents table** grows with uploads; consider archiving metadata for deleted/expired items and enforcing retention policies.
- **Events** should not live indefinitely in OLTP: keep a short window in Postgres, ship to data lake/WORM, and query via analytics tooling.

---

## Trade-offs

- **Async DLP with download gating**
  - Benefit: uploads stay fast and resilient; scanners don’t become the synchronous bottleneck.
  - Cost: external sharing is delayed until approval; requires clear UX (“Scanning…” states) and operational SLAs for scan latency.

- **Stateful authorization (DB as source of truth) vs purely signed URLs**
  - Benefit: revocation, max-download enforcement, and policy changes are effective quickly and auditable.
  - Cost: adds a control-plane dependency to downloads; requires careful caching and high availability for auth.

- **Dynamic watermarking at delivery time**
  - Benefit: strongest attribution; supports per-viewer identity and time without storing many variants.
  - Cost: higher compute cost and latency; rendering pipeline must be secure and scalable.

Alternative approaches (when to use them)
- **Pre-generate per-recipient copies**: simpler delivery but storage and management explode; revocation is harder (many derived artifacts).
- **CDN direct-serve originals**: great performance but poor fit for dynamic watermark and strong policy enforcement.
- **Inline synchronous scanning**: strongest immediate guarantee but fragile UX and turns scanners into a hard dependency.

---

## Failure Modes

### Scenarios and Responses

- **Redis outage**
  - Impact: higher DB load, increased auth latency.
  - Mitigation: fall back to DB; tighten rate limits; keep caches short-lived and optional; alert on DB CPU/latency.

- **DLP backlog or vendor outage**
  - Impact: documents remain `PENDING_DLP`; external sharing blocked.
  - Mitigation: prioritize “waiting-to-share” items; autoscale workers; degrade to “deny external” (fail closed) while allowing internal org access if policy permits.

- **Renderer overload/timeouts**
  - Impact: export downloads fail or slow.
  - Mitigation: backpressure (429), per-org quotas, autoscale, circuit breaker; allow VIEW mode if policy permits; if watermark is mandatory for export, fail closed.

- **KMS throttling/latency**
  - Impact: encrypt/decrypt delays.
  - Mitigation: envelope encryption with short-lived data key caching in-memory; request batching where possible; capacity planning and quota increases.

- **Token brute force / credential stuffing**
  - Impact: unauthorized access attempts.
  - Mitigation: strong token entropy (≥192-bit), WAF rate limits/challenges, anomaly detection, per-link rate limits, lockouts with safe UX, constant-time comparisons, hashed token storage.

- **Metadata DB partial outage**
  - Impact: authorization and revocation checks degrade.
  - Mitigation: multi-AZ, fast failover, conservative cached TTLs, and a “deny external downloads on uncertainty” posture until strong checks resume.

### Disaster Recovery

- **Targets**: RTO 30 minutes, RPO 5 minutes (metadata); object storage via cross-region replication where residency allows.
- **Backups**: Postgres PITR + snapshots; periodic restore drills.
- **Failover**: promote replica, switch traffic via DNS/traffic manager, verify policy enforcement and scan gating before re-enabling external downloads.

---

## Operations

### Security Operations

- Routine key rotation; support BYOK where required.
- Continuous dependency patching for document parsers/renderers; isolate render runtime and restrict syscalls/network.
- Tenant isolation: strict IAM boundaries, per-tenant encryption context, residency enforcement.

### Monitoring and Alerting (SLO-driven)

- **Auth SLO**: authorize success rate and P99 latency; alert on error budget burn.
- **Revocation correctness**: “revoke → deny” propagation time (target sub-second to a few seconds depending on cache TTL); alert on violations.
- **Scan pipeline**: queue lag, time-in-state, failure rate by scanner.
- **Renderer**: queue depth, timeout rate, median/P95 render duration, sandbox OOM/kill signals.
- **Abuse**: spikes in 403/410, entropy anomalies, hot IP/ASN, unusual token retry patterns.
- **Audit**: ingestion lag, write failures to WORM store, dedupe rates.

### Deployment

- Canary releases and feature flags for policy changes and watermark templates.
- Backward-compatible DB migrations (expand/contract).
- Regular game days: revoke correctness, scan gating, renderer isolation, regional failover.

### Compliance and Data Lifecycle

- Retention policies per org; legal hold support.
- GDPR/DSAR workflows: locate and export audit trails and documents; delete with tombstones and immutable audit of deletion.
- Immutable audit retention (WORM) configured per compliance requirements.

---

## References & Further Reading

- OWASP ASVS (Application Security Verification Standard): https://owasp.org/www-project-application-security-verification-standard/
- NIST SP 800-53 Rev. 5 (security controls): https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final
- AWS S3 Pre-Signed URLs (direct-to-object-store uploads): https://docs.aws.amazon.com/AmazonS3/latest/userguide/ShareObjectPreSignedURL.html
- Google Cloud Sensitive Data Protection (DLP concepts): https://cloud.google.com/sensitive-data-protection/docs
- S3 Object Lock (WORM/immutability): https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html
- Firecracker (microVM isolation, relevant to untrusted document processing): https://firecracker-microvm.github.io/