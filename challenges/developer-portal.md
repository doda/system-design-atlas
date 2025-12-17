## Elegance Check

### The Core Insight
Making the catalog **repo-native (Git as truth)** and scorecards **explainable with provenance + rule versioning** is the non-obvious move that prevents the “portal becomes a wiki” failure mode.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| `catalog-info.yaml` + CI validation | Forces correctness at the point of change; makes ownership and required links reviewable and versioned. |
| Postgres (system of record) | Enforces constraints/transactions for “high trust”; supports auditability and consistent reads for the portal. |
| Workers (connectors + scoring) | Keeps the read path fast and isolates flaky upstream APIs; enables freshness + “stale” as first-class state. |
| Override system (expiry + audit) | Acknowledges reality (break-glass) without destroying trust long-term. |
| Rebuildable search index | Separates “fast find” from “truth”; supports clean recovery after index corruption. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| OpenSearch from day 1 | Start with Postgres search (`tsvector`, `pg_trgm`) + facets via SQL; add OpenSearch only when latency/relevance demands it | Less fancy relevance at first; but fewer moving parts and easier on-call. |
| “Durable queue” unspecified | If already on Postgres: use transactional outbox + worker polling; or Redis Streams/SQS if available | Outbox adds DB load; Redis/SQS adds infra dependency but clearer semantics. |
| One worker fleet doing “connectors + scoring” | Split into two pipelines: ingestion → normalized signals tables; scoring reads only normalized tables | More schema work, but dramatically simpler scoring correctness and backfills. |
| Link “reachability” enforced in CI | Validate format + allowlist domains in CI; do reachability asynchronously in workers with caching | CI becomes less flaky; you lose hard blocking on transient outages. |
| Ghost services as a special entity type | Treat as “discovered workload” inventory separate from catalog entities, with a join hint to inferred repo/team | Prevents polluting the catalog model; slightly more UI work to present “unregistered” items. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: not explicitly addressed (mentions read-path SLOs, but DB is the core).
   - Recommendation: Strengthen — define degraded mode (serve cached service pages/scores), queue ingestion with backpressure, and a clear RPO/RTO + restore/runbook.

2. **OpenSearch is down / index is corrupted**
   - Design’s answer: addressed (“search down still allows direct service pages from Postgres”, “rebuilt from Postgres”).
   - Recommendation: Acceptable — ensure the UI has a first-class “search degraded” UX (browse by team/tier) and that rebuild time is bounded/observable.

3. **Upstream connector partial failure (rate limits, slow APIs, bad tokens)**
   - Design’s answer: addressed (connector error budgets, “last known good” + staleness banners, backoff).
   - Recommendation: Strengthen — specify per-signal semantics: when do you suppress scoring vs score-with-penalty, and how do you prevent “silent green” from stale evidence?

4. **Bad config / bad scoring rules roll out at 3am**
   - Design’s answer: addressed (versioned rules, canary cohort, rollback, freeze publication).
   - Recommendation: Strengthen — add “blast radius controls” (per-tier rollout, max-score-delta guardrails) and an explicit “ruleset pinned per org/team” escape hatch during incidents.

5. **Event loss / webhook spoofing / duplicate events**
   - Design’s answer: partially addressed (lag metrics, backfill, idempotency keys).
   - Recommendation: Must fix — define the event trust model (signature verification, replay protection), idempotency key strategy (what keys for which sources), and how you reconcile Git head vs ingested commit deterministically.

## Recommendations

### Must Fix
- **Queue/event semantics**: explicitly document at-least-once vs exactly-once expectations, idempotency keys per source, ordering assumptions, and the reconciliation algorithm (Git commit hash as the unit of truth helps).
- **AuthZ model clarity**: “hide sensitive services/docs without shadow catalogs” needs a concrete approach (entity-level ACLs, team membership resolution, audit of access, and how search respects permissions).
- **CI flake risk**: “required links reachable” will create false negatives (network/DNS/vendor outages); move reachability to async validation or make it non-blocking with signed exceptions.
- **Ghost/discovery lifecycle**: define when discovered workloads are created/merged/expired, and how you avoid permanently mis-attributing ownership from heuristics.

### Should Consider
- **Normalize signals before scoring**: store connector outputs as typed, timestamped facts; make scoring a pure function over facts to simplify recompute/backfill and explainability.
- **Start simpler on search**: Postgres-first search is often enough at 5k services; defer OpenSearch until you have measured need (or constrain OpenSearch to “docs titles/content” only).
- **Make “stale” a contract**: standardize freshness windows and UI language; avoid teams debating why a score changed when the real change was staleness.
- **Operational ownership**: pick a “one person can deploy safely” story (migrations, reindex, backfill, rollback) and make it boring/automated.

### Nice to Have
- **Golden-path tooling**: a CLI/template to generate `catalog-info.yaml`, plus CI autofix suggestions to reduce friction.
- **Policy-as-code**: express required links/tiers/override policy in a versioned rules repo so governance changes are reviewable.
- **Incident-mode UX**: a “service page works even when everything else is on fire” checklist (cached last-known-good, pinned runbook/on-call links, clear staleness).

## What’s Working Well
- The design optimizes for **trust and adoption** (repo-native truth + CI gatekeeping) instead of shiny UI features.
- Scorecards are treated as **auditable evaluations**, not magic numbers (rule versioning + evidence).
- Recovery thinking is pragmatic (reindex from Postgres, backfill playbook, explicit “stale” state).
- You’re honest about trade-offs and avoid a premature graph DB rabbit hole while still supporting relationships.