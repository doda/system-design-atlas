```markdown
---
title: "Capacity Planning & Autoscaling"
category: "Observability & Reliability"
difficulty: "Hard"
tags: ["autoscaling", "forecasting", "kubernetes", "sre", "capacity-planning"]
---

## Overview

This system is a predictive autoscaler that provisions compute *ahead* of demand using historical signals plus explicit safety margins. It targets the gap that reactive autoscaling can’t close: fast ramps (marketing blasts, cron-driven traffic, timezone peaks) where “scale after you’re hot” is already too late.

The key insight is to separate **prediction** from **actuation** and make the handoff mathematically explicit: predict a near-future demand distribution (not a single number), convert it into required capacity via a learned “cost per unit demand,” then add a safety margin that is tied to an error budget (coverage), not gut feel. Reactive autoscaling still exists—but as the seatbelt, not the engine.

A small team can build and run this by leaning on boring primitives: Prometheus/Thanos for metrics, Postgres for config and audit, and a Kubernetes controller that writes desired replica counts (or ASG desired capacity). The “smart” part is narrow: uncertainty-aware forecasting + guardrailed scaling decisions.

## What Makes This Hard

Naive predictive autoscalers fail because they treat forecasting as the whole problem. The trap is that **forecast error becomes an outage** unless you translate it into a safety policy with guardrails and clear fallbacks.

The second trap is **feedback loops**: autoscaling changes CPU/utilization, which changes the very signals you’re using to learn “how much capacity you need.” If you don’t disentangle “demand” from “resource saturation,” the model learns nonsense during incidents and then repeats it during the next peak.

## Requirements

### Functional Requirements

- Produce per-workload capacity plans for a fixed horizon (e.g., 5–30 minutes ahead) and apply them continuously.
- Encode safety explicitly: “scale to meet P95 demand with 99% coverage over the last 14 days” (or an equivalent SLO-driven rule).
- Support overrides and guardrails per workload (max step, max spend, minimum headroom, freeze conditions).
- Provide explainability: every scaling action is attributable to inputs, forecast, margin, and constraints.
- Fail safe: on bad data or model degradation, revert to reactive autoscaling without operator heroics.

### Scale Targets

- **Workloads:** 500 deployments across 10 clusters (typical mid-size platform team).
- **Decision cadence:** every 60s; **horizon:** 15 minutes (enough to cover node provisioning + pod warmup).
- **Signals:** 1-minute aggregates of demand proxy (RPS/queue depth) + resource usage (CPU/mem) + saturation (latency, 5xx).
- **Action volume:** worst case 500 workloads × 60 decisions/hour = 30k decisions/hour; only a small fraction should cause changes due to hysteresis.

These numbers matter because they force the design to be cheap, incremental, and robust to partial failures; you can’t run heavyweight retraining per decision, and you must keep metric cardinality under control.

## Key Design Decisions

- **Decision 1: Predict demand, not utilization**
  - **Chose:** forecast *demand proxies* (RPS, queue depth, scheduled jobs) and map to required resources via a learned cost model.
  - **Rejected:** forecasting CPU%/utilization directly.
  - **Why:** utilization is a controlled variable influenced by scaling; demand is closer to exogenous reality and is stable through incidents.

- **Decision 2: Safety margin via coverage, not fixed headroom**
  - **Chose:** quantile/coverage-based capacity (e.g., conformal prediction interval or empirical error quantiles) with explicit target coverage.
  - **Rejected:** “+30% buffer” everywhere.
  - **Why:** fixed buffers are wrong in both directions—wasteful for stable workloads, insufficient for spiky ones. Coverage ties cost directly to outage risk.

- **Decision 3: Predictive sets the baseline; reactive handles residual**
  - **Chose:** predictive scaler writes a *floor* (minimum replicas / desired capacity) while HPA (or target-tracking) still reacts to surprises.
  - **Rejected:** replacing reactive autoscaling.
  - **Why:** reactive is the last line of defense and a proven incident tool; predictive reduces the frequency and severity of “late scaling,” not all variance.

## Architecture

```mermaid
flowchart LR
  M[Metrics (Prom/Thanos)] --> F[Feature Builder]
  C[Config (Postgres)] --> P[Policy Engine]
  F --> R[Forecaster]
  R --> P
  P --> A[Scaling Controller]
  A --> K[K8s API / ASG]
  K --> M
  P --> L[Audit Log]
```

### Components

- **Metrics (Prometheus + Thanos):** short-term + long-term signals with consistent 1-minute downsampling; Thanos gives you “last 90 days” without inventing a custom store.
- **Feature Builder:** transforms raw metrics into stable demand features (time-of-week seasonality, recent trend, known batch schedules) and filters out saturated periods.
- **Forecaster:** outputs a demand distribution for each workload and horizon; optimized for fast incremental updates, not fancy research.
- **Config (Postgres):** per-workload policies, constraints, rollout state, and “what is the demand proxy for this service?” in one transactionally consistent place.
- **Policy Engine:** converts predicted demand into required replicas/nodes with coverage-based margin and guardrails (max step, cooldown, budget caps).
- **Scaling Controller:** applies decisions via Kubernetes (patch HPA minReplicas / scale subresource) and/or ASG desired capacity; owns backoff, retries, and idempotency.
- **Audit Log:** immutable record of every decision with inputs and outputs; required for debugging, postmortems, and trust.

## Deep Dive: Uncertainty-Aware Scaling (The Hardest Part)

The hardest part is turning “a forecast” into “an action” without turning forecast error into pager fatigue. The system does this in three explicit steps:

1) **Forecast a near-future demand distribution.** For each workload, predict demand for each minute in the next 15 minutes. Use a model that captures seasonality cheaply (time-of-week buckets + exponential smoothing on residuals). The output is not a point estimate; it’s an interval (or quantiles) per horizon step.

2) **Map demand to capacity using an efficiency model learned from healthy periods.** Convert demand to required CPU (and optionally memory) using robust regression over windows where saturation is low (e.g., latency below SLO and CPU < 70%). This avoids “incident learning,” where throttling makes CPU look flat while demand is actually rising. The output is a capacity requirement in millicores (or replicas given per-pod requests).

3) **Add safety margin using empirical coverage guarantees.** Maintain a rolling history of forecast errors per workload and time-of-week. Choose a target coverage (e.g., 99% of the time, capacity >= realized demand). Implement this as a conformal-style adjustment: widen the prediction interval by the (1-coverage) quantile of recent absolute errors. This is the crucial move: the margin automatically grows for spiky workloads and shrinks for stable ones, and it is measurable in production (coverage drift is an alertable metric).

Finally, the Policy Engine turns “required capacity” into a bounded action with guardrails:
- **Hysteresis:** don’t scale down unless you’ve been overprovisioned for N minutes.
- **Max step:** cap increases/decreases per minute to avoid runaway and to respect warmup.
- **Freeze on anomalies:** if data quality drops or coverage collapses, stop predictive writes and let reactive autoscaling run alone.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Fast ramps without latency spikes | Some steady-state efficiency |
| Explicit, measurable risk (coverage) | Model simplicity over maximum accuracy |
| Operational safety and reversibility | Per-workload tuning still required |
| Small-team operability | Less “one size fits all” automation |

## Failure Modes

- **Bad metrics / gaps**
  - **What happens:** forecaster underestimates demand or cannot compute features; scaling actions become noisy or absent.
  - **Detect:** data freshness SLOs (scrape lag), missing-series rate, sudden drops to zero, feature build error rate.
  - **Recover:** freeze predictive actions for affected workloads, fall back to reactive autoscaling, page only if fallbacks also fail.

- **Model drift / coverage collapse**
  - **What happens:** forecasts systematically miss (new traffic pattern, product launch), causing underprovisioning.
  - **Detect:** online coverage metric (fraction of intervals where realized demand exceeded predicted-with-margin), plus SLO burn correlation.
  - **Recover:** automatically widen margin (increase error quantile window), trigger shadow backtest, require human approval to reduce margin again.

- **Actuation failure (K8s/ASG throttling, controller bugs)**
  - **What happens:** decisions are computed but not applied; capacity lags behind demand.
  - **Detect:** reconcile errors, API rate-limit metrics, “desired vs applied” diff, and time-to-effect histograms.
  - **Recover:** exponential backoff + idempotent patches, reduce write frequency under throttling, and surface a single “predictive autoscaler degraded” alert.

## What I'd Do Differently At...

- **10x scale:** shard by cluster and move feature computation closer to metrics (per-cluster builders); add a lightweight stream (Kafka) only if metric polling becomes cost-dominant.
- **100x scale:** split forecasting into offline + online: offline learns per-service demand/capacity models and priors; online only does residual updates and conformal margins. Also, stop using raw Prometheus queries as the feature substrate—emit curated “autoscaling signals” as a first-class product.

## Operational Notes

- Run in **shadow mode** first: compute decisions and margins, but don’t apply; publish coverage and “would-have-scaled” deltas to earn trust.
- Treat **coverage** as the primary KPI; cost is a secondary KPI you optimize only after coverage is stable.
- Maintain an explicit **blocklist**: workloads with unstable demand proxies (batchy, multi-tenant) shouldn’t use predictive until they expose a better signal.
- Every applied change must be traceable in `Audit Log` with a stable decision ID and the exact inputs/constraints used.
```