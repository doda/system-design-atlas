```markdown
---
title: "SLO/Error Budget Monitoring"
category: "Observability & Reliability"
difficulty: "Medium"
tags: ["sre", "slo", "error-budgets", "prometheus", "alerting", "burn-rate", "grafana"]
---

## Overview

This system tracks SLO compliance by continuously measuring SLIs, converting them into **error budget burn rates**, and alerting when burn indicates the budget will be exhausted before the SLO window ends. The key insight is to **treat SLO monitoring as a rules-generation problem**, not a bespoke analytics platform: we compile SLO definitions into a small, repeatable set of recording rules and multi-window burn alerts executed by a proven Prometheus-compatible time-series backend.

The elegant part is separating concerns cleanly: services emit **boring, low-cardinality golden signals** (good/total events); a rule compiler turns human-readable SLO specs into deterministic queries; the metrics backend evaluates them at low cost; Alertmanager handles routing/dedup/escalation. The only “custom” code is the compiler and a thin API/UI around SLO lifecycle.

## What Makes This Hard

Naive implementations get trapped by two things:

1. **Math that lies under pressure.** If you compute “average error rate” incorrectly (ratio-of-averages vs average-of-ratios, poor aggregation, counter resets, missing data), you page people for ghosts or miss real incidents. Burn rate math is simple; making it correct on real telemetry is not.

2. **Alerting that is either noisy or late.** Single-window alerts flap (5m noise) or arrive too late (6h smoothing). The non-obvious fix is **multi-window, multi-burn** alerting: require a fast window and a slow window to agree, which catches sustained incidents quickly while rejecting brief spikes.

## Requirements

### Functional Requirements
- Define SLOs per service/user journey with: objective, rolling period (e.g., 30d), and an SLI expressed as *good/total* events.
- Continuously compute:
  - Burn rate across multiple windows (e.g., 5m, 30m, 1h, 6h).
  - Error budget remaining for the rolling period.
- Trigger alerts based on burn-rate policies (paging vs ticket) and budget exhaustion forecasts.
- Provide dashboards per SLO: current SLI, burn rates, remaining budget, top contributors (by route/region where safe).
- GitOps workflow: reviewed changes, versioned policies, auditable history.

### Scale Targets
- **SLO count:** 1,000 SLOs (500 services × 2 key SLOs). Matters because rule count and evaluation cost scale with SLOs.
- **Ingestion:** ~500k–2M samples/sec across the fleet. Needs a horizontally scalable TSDB (not a single Prometheus).
- **Rule eval:** 1-min evaluation interval; alert latency target <2 minutes from sustained incident start.
- **Cardinality budget:** per-SLO evaluation should touch O(10–100) series, not unbounded labels.

## Key Design Decisions

- **Choose Prometheus-compatible metrics + ruler (Mimir/Cortex/Thanos Ruler).**
  - Rejected: building a custom time-series compute engine.
  - Why: burn rate and budget math map cleanly to PromQL; ruler is battle-tested and operationally boring.

- **Define SLIs as event counters (good/total), not latency histograms by default.**
  - Rejected: “just compute it from logs/traces.”
  - Why: counters are cheap, robust, and aggregate correctly. Logs/traces are great for debugging, not for being your primary SLO source of truth.

- **Generate recording/alerting rules from SLO specs (Sloth-style).**
  - Rejected: hand-written PromQL per SLO.
  - Why: consistency prevents subtle math bugs; policies become reusable; onboarding a new SLO becomes a small config change, not bespoke query design.

## Architecture

```mermaid
flowchart LR
  A[Services] --> B[OTel Collector]
  B --> C[Metrics Backend]
  D[SLO Specs (Git)] --> E[Rule Compiler]
  E --> C
  C --> F[Alertmanager]
  F --> G[On-call / Tickets]
  C --> H[Grafana]
```

### Components

- **Services**
  - Emit `good_total` and `total` counters (or `errors_total` + `total`) for each SLO-able operation, with strict label hygiene.

- **OTel Collector**
  - Standardizes, batches, and forwards metrics via remote write; isolates app code from backend changes.

- **Metrics Backend (Mimir/Cortex/Thanos)**
  - Durable, horizontally scalable store for time series; runs recording/alerting rules close to the data.

- **SLO Specs (Git)**
  - YAML definitions: objective, period, SLI selector expressions, alerting policy, ownership.
  - Enables review, rollback, and audits (“who changed paging thresholds?”).

- **Rule Compiler**
  - Compiles each SLO into:
    - Recording rules (precompute per-SLO error ratio time series).
    - Multi-window burn alert rules and “budget remaining” rules.
  - Enforces guardrails: max label sets, required aggregations, required ownership/routing.

- **Alertmanager**
  - Dedup, inhibit, route (service owner, severity), escalation, quiet hours, grouping.

- **Grafana**
  - Standard dashboards per SLO + fleet views; links to runbooks and recent incidents.

## Deep Dive: Correct Burn-Rate Alerts (Without Noise)

The core quantity is **burn rate**:

- Let `objective = 0.999` over `period = 30d`
- Error budget fraction `budget = 1 - objective = 0.001`
- For a window `w`, measured error fraction:
  - `err_frac(w) = errors(w) / total(w)` (ratio of sums, not sum of ratios)
- Burn rate:
  - `burn(w) = err_frac(w) / budget`

A fast page should mean: “if this continues, we’ll blow the monthly budget soon.” A clean policy is multi-window, multi-burn:

- **Page (fast):** `burn(5m) > 14` AND `burn(1h) > 14`
- **Ticket (slow):** `burn(30m) > 6` AND `burn(6h) > 6`

Why it works:
- The fast window catches sharp regressions quickly.
- The slow window prevents paging on transient spikes and metric jitter.
- The burn thresholds map to time-to-exhaustion: `time_to_burnout ≈ period / burn`.  
  Example: burn=14 on a 30d SLO implies exhaustion in ~2.1 days if sustained—worth paging.

Implementation detail that prevents subtle wrongness:
- Compute `errors(w)` and `total(w)` from **counters** using `rate()` and `sum()` with consistent aggregation, then derive ratios.
- Avoid per-instance ratios (they overweight small instances). Always do **ratio after aggregation**:
  - Good: `sum(rate(errors_total[5m])) / sum(rate(total_total[5m]))`
  - Bad: `avg(rate(errors/total))`

Budget remaining is derived over the rolling period:
- `consumed = (1 - sli_period) / budget`
- `remaining = 1 - consumed`
Where `sli_period` uses ratio-of-sums over the full rolling window (often via recording rules to keep it cheap).

Missing data is handled explicitly:
- If `total(w)` is ~0 (no traffic), burn is undefined; we do **not** page on “no requests.”
- Separate alert: “SLO telemetry missing” when the required series are absent for N minutes, routed to the owning team (this is a monitoring failure, not an SLO failure).

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Correctness of burn math | Flexibility of arbitrary ad-hoc SLIs |
| Low operational novelty | “Single pane” custom analytics features |
| Fast, low-noise paging | Perfect sensitivity to very short spikes |
| Cost control via low cardinality | Per-dimension SLOs (e.g., per-customer) |

## Failure Modes

- **Telemetry gap / remote-write outage**
  - Happens: burn and remaining become misleading or flatline.
  - Detect: “absent series” + remote-write error rate + ingestion lag.
  - Recover: alert on telemetry failure separately; buffer at collector; ensure backend HA; avoid paging on undefined burn.

- **Cardinality explosion (labels drift into SLI metrics)**
  - Happens: backend cost spikes, queries slow, rule eval falls behind; alerts become delayed.
  - Detect: per-metric series count SLO + ruler eval duration + top-cardinality reports.
  - Recover: compiler rejects bad label sets; enforce metric linting in CI; push aggregation to the edge (collector).

- **Incorrect SLI query (math/aggregation bug)**
  - Happens: chronic false pages or missed outages across many services.
  - Detect: canary SLOs with known behavior; diff-based review of generated rules; “SLO sanity” dashboards (error fraction should match logs during incidents).
  - Recover: rollback SLO spec/rules; ship compiler fix; require approval for new SLI templates.

## What I'd Do Differently At...

- **10x scale:**
  - Move to dedicated ruler pools, aggressive recording rule precomputation, and strict evaluation budgets per tenant/team.
  - Introduce automated “top offenders” attribution using a controlled dimension set (region, cluster, endpoint class), not raw paths.

- **100x scale:**
  - Split metrics storage by tenancy (org/team), enforce hard per-tenant series quotas, and consider streaming pre-aggregation for ultra-hot signals.
  - Treat SLO evaluation as a product: cached query frontends, rollup tiers, and strong SLO-template standardization to keep queries uniform.

## Operational Notes

- Standardize a small SLO template library (availability, latency-<T, freshness) and ban bespoke PromQL unless reviewed.
- Keep burn alerts owned: every SLO must declare `owner`, `runbook`, and `paging policy`.
- Separate “service bad” from “monitoring blind”: missing-telemetry alerts should never page the same way as budget burn.
- On-call ergonomics: alerts include current burn rates (fast+slow), remaining budget, and a Grafana deep link scoped to the SLO.
```