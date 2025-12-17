```markdown
---
title: "Configuration Distribution System"
category: "Foundational Infrastructure"
difficulty: "Hard"
tags: ["config", "control-plane", "rollouts", "validation", "versioning", "fleet-management"]
---

## Overview

This system is a configuration control plane + distribution path for a large fleet. Configs are immutable artifacts; “what’s live” is just a metadata pointer per cohort. Rollback is a pointer flip, not a rewrite.

The whole design is: Postgres for activation truth + audit, object storage + CDN for artifacts, and a node agent that can safely apply (atomic swap + last-known-good). Distribution is pull-first (cacheable `desired` endpoint + jitter); an optional “poke” channel can shorten convergence, but correctness never depends on it.

## What Makes This Hard

Naive designs optimize for “read the latest value” and ignore that the real blast radius comes from *activation*. The trap: schema validation is necessary but not sufficient—many failures are semantic (timeouts, feature interactions, latent assumptions). If “latest” auto-propagates to every node, a single bad publish becomes a fleet-wide incident.

The second trap is the update storm. If the fleet converges by hammering the control plane, you DDoS yourself. The solution is to make reads cacheable, serve artifacts from the CDN, and make every agent back off and jitter.

## Requirements

### Functional Requirements
- Publish config bundles with schema validation and immutability (audit-friendly, reproducible).
- Support both pull (agents polling) and push (near-real-time notification) without requiring long-lived connections from every node.
- Versioning with explicit activation targets (by service, environment, region, cohort).
- Safe rollouts: canary, progressive rollout, and fast rollback.
- Strong authentication/authorization and tamper resistance (prevent config injection).

### Scale Targets
- Fleet: 200k nodes across 20 regions.
- Config size: median 10 KB, p99 200 KB (bundled per service/env).
- Change rate: 1,000 publishes/day; 50 “hot” rollouts/day that must converge in <5 minutes.
- Read path: steady-state polling at 60s with jitter → ~3,300 rps globally; bursty convergence after pokes.
- Availability: 99.95% for reads; 99.9% for publishes (reads are the lifeblood, writes can queue briefly).

## Key Design Decisions

- **Push-notify / pull-fetch**
  - Chose: pull is truth (`GET desired` with ETag/304 + jitter); artifacts fetched over HTTPS from CDN.
  - Push: an optional, best-effort “poke” endpoint (e.g., SSE) that only tells agents “check now”; polling still works and is always sufficient.

- **Immutable artifacts + metadata activation**
  - Chose: configs stored as content-addressed blobs with signed manifests; Postgres stores rollout state (`cohort → desired_version_id`) and a monotonic `epoch`.
  - Why: rollback is an O(1) pointer change; caching is safe; “what happened” is an audit query.

- **Agent-managed last-known-good (LKG)**
  - Chose: a local config agent that atomically swaps versions, runs validation hooks, and can self-revert.
  - Why: safe apply/rollback is the hard part; keeping apps dumb prevents a hundred subtly broken clients.

- **Deterministic cohorts (plus overrides)**
  - Chose: cohorts are mostly computed (consistent-hash by `node_id` into percent buckets) with a small override list for “pin this node.”
  - Why: fewer moving parts and fewer per-agent lookups while still supporting canaries and targeted fixes.

## Architecture

```mermaid
flowchart LR
  A["Config CLI/UI"] --> B["Config API"]
  B --> C["Postgres (metadata)"]
  B --> D["Blob Store (artifacts)"]
  G["CDN/Edge Cache"] --> D
  H["Config Agent"] -->|poll desired (ETag)| B
  H -->|fetch artifact| G
  H -.->|optional poke subscribe| B
```

### Components

- `Config CLI/UI`: Creates bundles, selects schemas, and starts rollouts; must make “who gets this when” explicit.
- `Config API`: The control plane. Owns authz, validates bundles, signs manifests, writes metadata, issues pre-signed artifact URLs, and exposes “desired version for my cohort.”
- `Postgres (metadata)`: Source of truth for schemas, versions, rollout state, cohort definitions, and audit logs. Strong consistency matters for activation.
- `Blob Store (artifacts)`: Stores immutable config bundles and manifests. Cheap, durable, horizontally scalable.
- `CDN/Edge Cache`: Serves artifacts (and can cache `desired` responses) so rollouts don’t overload the control plane.
- `Config Agent`: Runs on every node. Polls desired version (and may accept best-effort pokes), downloads artifacts, verifies signatures, applies atomically, and keeps LKG.

## Deep Dive: Safe Rollouts and Rollbacks (The Hardest Part)

The system models rollout as a **desired-state pointer** per cohort, not “latest config.” Each publish creates an immutable artifact `artifact_hash` and a semantic `version_id` (monotonic per service/env). Activation is a separate transaction that updates `(cohort, desired_version_id, epoch)` in Postgres with optimistic locking; each change increments `epoch`, making ordering explicit and eliminating rollout-vs-rollback races.

Publishing is two-phase: upload artifact → compute/verify `artifact_hash` → write metadata (schema, hash, manifest, audit) → only then allow activation to reference it. Agents never see a desired version whose artifact isn’t readable from the CDN.

On the node, the agent maintains three directories: `active/`, `staged/`, and `lkg/` plus a small state file with the currently active `version_id` and `artifact_hash`. When a new desired version appears (via poll or poke), the agent downloads to `staged/`, verifies:
1) manifest signature (trusted key set),
2) artifact hash (content-addressed),
3) schema compatibility (local schema version constraints),
then runs an **application-specific acceptance hook** (fast, deterministic checks like “can parse,” “required endpoints present,” “feature flags consistent”). Only then does it atomically swap `staged/` → `active/` (rename is atomic on the same filesystem) and preserve the previous `active/` as `lkg/`.

Rollouts progress via cohorts: e.g., `canary-1%`, `canary-10%`, `region-us-east`, `global`. Cohort membership is computed from authenticated agent identity (`service/env/region/node_id`) plus override pins (the API derives identity from credentials, not from agent-supplied labels), so “who is in the canary” is stable. Progression is explicit operator action (optionally with a small automation loop) gated on **independent telemetry** (service SLOs), not just “agent applied successfully.”

Rollback is a metadata flip: set the cohort’s desired version back to the prior known-good `version_id` (with a new `epoch`). Agents converge via polling (and any best-effort pokes). Independently, any agent can self-revert to `lkg/` if its acceptance hook or post-apply health probe fails.

Degraded-mode contract is strict: if the control plane is unreachable or returns inconsistent data, agents keep the current `active/` and never “guess latest.”

Trust model is minimal and explicit: each agent embeds a root public key; the control plane publishes a signed keyset (current allowed signing keys + key IDs). Manifests are signed with a rotating signing key and include `key_id`; agents accept a manifest only if `key_id` is in the latest root-signed keyset. Revocation is “remove key_id from keyset,” not “hope nobody cached the old key.”

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Fast, safe rollback | “Always latest” simplicity |
| Predictable read scaling | Guaranteed push delivery |
| Auditability and reproducibility | Slightly higher publish complexity |
| Fleet resilience (LKG + caching) | More logic in the agent |

## Failure Modes

- **Bad config passes schema but breaks behavior**
  - What happens: elevated errors/crashes after activation in a cohort.
  - Detect: operator gates rollout steps on service SLOs + agent self-revert rate; alerts on cohort-correlated regressions.
  - Recover: metadata rollback to prior `version_id`; nodes that already broke self-revert to LKG.

- **Signer key compromise / malicious publish**
  - What happens: attacker can produce “validly signed” manifests until revoked.
  - Detect: key usage anomaly + publish audit trail.
  - Recover: remove `key_id` from the root-signed keyset (agents reject new manifests), rotate keys, and rollback cohorts to a known-good `version_id`.

- **Postgres failover / control-plane read degradation**
  - What happens: agents struggle to fetch desired version; risk of fleet stalling on old configs.
  - Detect: elevated API latency/5xx; database replication lag alarms.
  - Recover: agents pin to last-known desired/active (no flapping); `desired` is served from cache when possible; artifacts still served from CDN; publishes/activations pause until DB is healthy.

- **Network partition (region can’t reach control plane, can reach CDN)**
  - What happens: region can keep running, but won’t discover new desired versions.
  - Detect: regional drop in successful `desired` polls.
  - Recover: agents continue with active/LKG; operators can treat the region as frozen until control-plane access returns.

- **Poke storm / thundering herd**
  - What happens: too many nodes attempt to converge at once.
  - Detect: elevated 429/5xx, CDN/origin egress spikes, increased agent backoff.
  - Recover: agents enforce jitter + exponential backoff + max concurrent downloads; artifacts remain CDN-served so control plane stays out of the hot path.

## What We Removed

- Separate `Validator/Signer` service: validation + signing is a synchronous publish step inside `Config API`.
- Dedicated `Pub/Sub (notify)` component: correctness is polling; push is a best-effort poke endpoint on `Config API`.
- Bespoke cohort mapping system: cohorts are computed (hash buckets) with a small override list.
- Extra read caches for “desired version”: `desired` is HTTP-cacheable (ETag/304); add more only if you hit real limits.

## Operational Notes

- Treat signing keys like production TLS keys: rotate, audit, and keep offline break-glass procedures.
- Measure and alert on: time-to-converge per cohort, artifact download error rates, self-revert counts, and “config drift” (active version != desired).
- Enforce “no direct writes to production cohorts”: every activation requires a rollout plan (canary → widen → global) with recorded approver identity.
- Keep schemas versioned and compatibility rules explicit (e.g., agents refuse configs requiring a newer agent capability).
```
