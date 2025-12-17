## Elegance Check

### The Core Insight
Leases turn “stop” from an unreliable command into an automatic property: the system becomes safe even when the control plane is unhealthy, partitioned, or overloaded.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Target Agents | Only place you can *guarantee* rollback when the control plane can’t reach the target; anchors fail-closed behavior. |
| Lease mechanism | Makes fault injection self-terminating; converts many complex failures into “wait for TTL.” |
| Guardrail Evaluator (separate loop) | Prevents “runner is sick exactly when you need safety”; cleanly owns “deny renewals” logic. |
| Postgres | Good fit for durable state transitions, idempotency, approvals/audit metadata, and reconciliation after crashes. |
| Audit Log (WORM) | Builds trust for prod usage; provides tamper-resistant incident forensics and policy accountability. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Per-target lease rows + frequent renewals persisted in Postgres | Signed short-lived lease tokens (JWT/PASETO) verified locally; persist only step/epoch changes | Loses fine-grained per-renewal history; requires key management and careful revocation semantics. |
| Separate services for Controller + Evaluator | Single deployable with hard isolation (separate worker pools, circuit breakers, independent health checks) | Less “organizational independence”; but much simpler for a small team/on-call. |
| Guardrails via ad-hoc PromQL queries | Prometheus recording rules / precomputed SLO burn rates used by evaluator | Less flexibility per experiment; requires up-front guardrail templates (which you already want). |
| Custom target selection rules | Leverage K8s labels + topology spread constraints + a “diversity sampler” library | Might not capture bespoke dependency graphs; but covers most correlated-blast-radius mistakes. |
| Custom chaos primitives (tc/iptables/process kill) everywhere | Prefer service-mesh faults where possible; reserve host-level agent for the hard cases | Mesh isn’t universal; some failure modes (node/network) still need host-level injection. |
| “Global kill switch” as a bespoke pathway | Implement as “epoch bump” (global deny) plus optional push revoke | Requires agents to poll/watch epoch; but it’s mechanically simple and auditable. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: not explicitly addressed (DB is central to state/leases).
   - Recommendation: Strengthen — ensure *existing injection still stops* (agent TTL), and define what happens to new runs/renewals when DB is unavailable (ideally: no new experiments, renewals fail closed).

2. **Prometheus is delayed 60s or partially missing**
   - Design’s answer: addressed (“unknown => stop”, optional grace).
   - Recommendation: Acceptable — but clarify the exact “unknown” detector (staleness thresholds, required series quorum) and how you avoid stopping due to a single scrape hiccup (bounded grace + consecutive unknowns).

3. **Network partition: control plane can’t reach one cluster**
   - Design’s answer: indirectly addressed (leases expire).
   - Recommendation: Strengthen — spell out whether agents require inbound calls (push renewals) vs outbound polling; outbound polling tends to fail-closed more predictably through NAT/firewalls.

4. **Bad config deploy causes evaluator to deny renewals globally**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen — add “safe config rollout”: canary evaluator, config version pinning per experiment, and a human-breakglass path that is explicit (and audited) rather than “just revert fast.”

5. **Traffic 10x spike during an experiment (slow, not failing)**
   - Design’s answer: partially addressed (ramp + guardrails).
   - Recommendation: Strengthen — guardrails should incorporate “baseline drift” protection (compare vs pre-step baseline) and have clear precedence rules (e.g., global service SLO breach stops all experiments touching that service).

## Recommendations

### Must Fix
- Make the p99 stop latency math explicit: with `5s` eval cadence and `10–15s` TTL, worst-case stop can exceed `10s`; either shrink TTL/renew interval or rely on a fast revoke channel (epoch bump + agent polling).
- Define lease validity precisely under clock skew (agent clock wrong, NTP drift): use server-issued expiries + monotonic epochs, and consider “max local injection duration” independent of wall time.
- Clarify kill switch propagation: what *exactly* do agents check (global epoch? per-experiment epoch?), how often, and what happens if the control plane is unreachable (should still stop via TTL).

### Should Consider
- Reduce Postgres write amplification: don’t persist every renewal; persist step transitions + “current epoch/deny state,” and keep renewals as stateless token refreshes.
- Precompute guardrails (recording rules) and standardize templates per tier; it lowers Prometheus load and makes “unknown telemetry” detection more deterministic.
- Formalize blast-radius “diversity constraints” (AZ, nodepool, shard, tenant) in the experiment spec so “1%” can’t accidentally mean “all from one hot shard.”

### Nice to Have
- Multi-signal safety: allow a small set of independent signals (e.g., blackbox probes, client-side error counters, or service-owned SLIs) so a single telemetry backend hiccup doesn’t always force a stop.
- Per-target “stuck rollback” automation ladder: restart pod/netns → cordon/drain node → page, with clear timeouts and audit trails.
- “Experiment report” auto-generated from stored events (hypothesis, ramp steps, guardrail decisions, exact targets) to build adoption trust.

## What’s Working Well
- The separation of experimentation vs safety is the right abstraction; it keeps the design honest under degraded observability.
- Leases are a genuinely elegant core: they constrain the worst failure mode (can’t stop) into a bounded, testable window.
- Progressive ramp + mandatory observe phases is the right operational ergonomics; it turns chaos into something interpretable and reviewable.
- You’re explicit about trade-offs (false positives, lower throughput) and align them with a realistic concurrency cap—good “small team can own it” thinking.