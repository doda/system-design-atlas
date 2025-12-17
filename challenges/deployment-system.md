## Elegance Check

### The Core Insight
Treating rollout automation as **SLO-governed risk allocation** (burn-rate + baseline deltas + “INCONCLUSIVE is a stop signal”) is the genuinely non-obvious part, and it’s the right abstraction to keep teams from disabling automation.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| `Release` CRD + controller | Idempotent orchestration with a single desired-state interface and restart safety. |
| Traffic router (mesh/ingress) | Makes rollback mean “remove exposure in seconds,” independent of pod lifecycle. |
| Prometheus | Existing substrate for SLIs and operational reality; avoiding a new metrics stack is a win. |
| Audit trail (some durable store) | Post-incident “why did it fail?” requires immutable evidence, not just current status. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom Deploy API as single entry point | Use Kubernetes API directly + `ValidatingAdmissionPolicy`/OPA/Kyverno + GitOps (Argo CD/Flux) | Less “CI-friendly” bespoke UX unless you build a thin CLI; but fewer services to operate. |
| Separate “Analysis Engine” service | Put analysis as a controller library / sidecar worker, or adopt Argo Rollouts/Flagger analysis hooks | Fewer moving parts; but you may lose isolation/blast-radius and need careful controller resource limits. |
| Postgres for “audit/state” | Keep **state only in CRD**; use Postgres/S3 only for **append-only audit** (or use event streaming if you already run Kafka) | Removes split-brain risk; still keeps debuggability. |
| Frequent raw PromQL per rollout | Use Prometheus recording rules / precomputed SLI series (or Thanos/Mimir ruler) + controller reads 1–3 series | More upfront SLO plumbing; dramatically reduces query cost and variability. |
| “Signed decisions” | Rely on Kubernetes RBAC + controller identity + append-only audit immutability (WORM bucket) | Less crypto/key management; slightly weaker tamper-evidence if cluster/admin is compromised. |

## Stress Test

### Failure Scenarios

1. **Postgres is down for 5 minutes**
   - Design's answer: addressed as “audit/state,” but failure behavior isn’t specified.
   - Recommendation: Strengthen — make CRD status the source of truth; if audit sink is down, continue rollout but mark `audit_write_degraded` and buffer/flush later (or explicitly fail closed if compliance requires it).

2. **Prometheus is slow (not down): queries time out intermittently**
   - Design's answer: “INCONCLUSIVE → pause,” retry/backoff.
   - Recommendation: Strengthen — define a clear escalation ladder: (a) hold step, (b) extend window once, (c) fail closed after max hold, and make the “hard stop only” fallback explicitly opt-in per service (otherwise you’ll ship blind during metrics brownouts).

3. **Router update succeeds, but router later becomes unavailable during rollback**
   - Design's answer: assumes router can always cut traffic quickly.
   - Recommendation: Strengthen — define “safety invariants” and what to do when they’re violated: if you can’t reduce canary weight, page immediately, freeze further rollout actions, and have an emergency manual path (documented runbook + one command) for forcing route to stable.

4. **Label/identity drift: canary and baseline cohorts aren’t cleanly separated**
   - Design's answer: mentions label sanity, version labels present/stable.
   - Recommendation: Must strengthen — use an immutable identity for cohorting (e.g., workload `pod-template-hash`/revision + image digest), and explicitly detect overlap/empty cohorts (“baseline includes canary pods” / “canary has <N pods”) as `INCONCLUSIVE` with a loud reason.

5. **10x traffic spike mid-rollout**
   - Design's answer: baseline comparison helps; burn-rate is impact-aligned.
   - Recommendation: Acceptable with one addition — cap *rate of exposure change* and require minimum stable time at each weight; spikes can make “fast window” too reactive unless you also model saturation and enforce “don’t advance while autoscaling/queueing is unstable.”

## Recommendations

### Must Fix
- Define a single source of truth: `Release.status` drives decisions; Postgres is append-only audit (or clearly specify what breaks if Postgres is unavailable).
- Specify router failure handling and invariants (rollback must succeed fast; if not, page + freeze + manual override path).
- Make cohort identity unambiguous (digest/revision-based) and treat cohort ambiguity as a first-class stop condition.
- Clarify concurrency rules (e.g., only one active `Release` per service/environment; what happens if CI submits two).

### Should Consider
- Adopt/extend an existing progressive delivery controller (Argo Rollouts/Flagger) and put your “SLO burn-rate + baseline delta + inconclusive semantics” into the analysis templates/plugins—this keeps the elegant core and deletes a lot of bespoke orchestration.
- Shift Prometheus load left: recording rules for SLIs + shared cached baselines per service/cluster; your stated query rate will become an operational constraint quickly.
- Make “INCONCLUSIVE timeout policy” explicit per service tier (tier-0 fails closed with fast paging; low-risk services can auto-advance only after additional safeguards).

### Nice to Have
- Dry-run mode that shows the exact queries, thresholds, and expected step schedule before touching traffic.
- Replay tooling: given an audit record, re-evaluate decisions against archived metrics to debug false positives/negatives.
- A small, opinionated runbook bundle (“stuck rollout,” “router degraded,” “metrics degraded”) linked from every alert.

## What's Working Well
- The separation of concerns (K8s executes, router exposes, analysis decides) is clean, and the state machine + idempotency emphasis matches real failure modes.
- Treating missing/noisy data as a stopping condition (not a “pass”) is the right cultural and technical default.
- The rollback ordering (cut traffic → preserve debugability → scale down) is operationally mature and avoids the classic “fixed the incident but lost the evidence.”
- The design is honest about trade-offs and scale drivers (Prometheus query cost, edge-triggered control loops), which sets you up for a credible production story.