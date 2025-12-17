```markdown
## Elegance Check

### The Core Insight
Treat the WAF as a **deterministic, precompiled data-plane program** with strict resource caps, and push all ambiguity (authoring/tuning/rollout/analytics) into a **control plane**. This is the right axis to optimize for adversarial inputs and operational safety.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Edge Proxy | The cheapest place to enforce hard caps, timeouts, and canonicalization before anything expensive happens. |
| WAF Filter (Data Plane) | Guarantees bounded-time decisions with no network dependencies; the “line-speed” core. |
| Rule Control Plane | Rules are code; you need workflow, provenance, staging, and guardrails. |
| Signed, Versioned Rule Artifacts | Makes rollback, auditability, and offline POP operation possible without trusting the network. |
| Event Stream (Async Telemetry) | Enables tuning and incident response without coupling observability to request latency. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom edge proxy + custom filter | Build as an **Envoy/Nginx module** (native filter) using existing HTTP/2/3, parsing, limits, and config plumbing | Less total control; you inherit proxy upgrade/patch cadence, but you remove a huge surface area. |
| Dedicated “Rule Distributor” service | **Pull-based distribution** from object storage (S3/GCS) fronted by CDN, with POPs polling + backoff + pinning | Slightly higher rollout latency; much simpler failure behavior (POPs keep last-known-good). |
| Bespoke rule language/runtime | Start with **OWASP CRS / ModSecurity semantics** but compile to your bounded primitives | Less bespoke expressiveness; faster maturity and clearer user mental model. |
| Custom event stream | Use **Kafka/Kinesis/PubSub** with explicit “drop-on-overload” policy at the edge | More ops cost (or managed spend); less custom reliability engineering. |
| Control-plane UI as primary authoring surface | **GitOps** (PRs + CI compile/bench + signed release) as the source of truth | Slower for emergency edits unless you add break-glass; dramatically better auditability and safety. |

## Stress Test

### Failure Scenarios
1. **Control plane or rules DB down for 5 minutes**
   - Design's answer: partially addressed (“break-glass”, version pinning implied)
   - Recommendation: **Strengthen** — make POP behavior explicit: “serve with last-known-good indefinitely,” local cache TTL policy, and a *locally configurable* global downgrade knob that does not require the control plane.

2. **Network partition between POPs and rule distribution**
   - Design's answer: not addressed (assumed by “no network calls” in data plane, but distro semantics unclear)
   - Recommendation: **Strengthen** — define pull/pin semantics, max staleness, and how you prevent “split-brain policy” during an incident (e.g., freeze upgrades unless explicit operator override).

3. **Event stream/analytics is slow or down**
   - Design's answer: implied async, but no backpressure policy described
   - Recommendation: **Must strengthen** — guarantee telemetry can never add latency: bounded in-memory queue + sampling + immediate drop once full; publish local counters even if detailed events drop.

4. **Bad ruleset causes CPU spikes (even without regex backtracking)**
   - Design's answer: “cheap first, expensive rarely,” caps mentioned
   - Recommendation: **Strengthen** — add *pre-deploy cost gates* (compile + microbench on worst-case inputs) and *runtime circuit breakers* (per-phase time budget, “disable body inspection” trigger, per-rule hit-rate anomaly auto-demotion to `LOG_ONLY`).

5. **Challenge path breaks users or becomes a new dependency**
   - Design's answer: action exists, implementation unspecified
   - Recommendation: **Strengthen** — make challenges **stateless** at the edge (HMAC-signed token/cookie with short TTL, key rotation plan) so you don’t introduce a global state store or per-request lookup.

## Recommendations

### Must Fix
- Specify **artifact trust model**: signing keys, verification in POP, rotation, and what happens on key compromise (at least “stop accepting new artifacts; pin last-known-good”).
- Define **telemetry backpressure** behavior so observability outages never become edge outages.
- Make **challenge** explicitly stateless (or explicitly justify state) and describe failure behavior (JS/CAPTCHA provider down, clock skew, token replay).
- Add **bounded execution enforcement** beyond input size (per-request CPU/time budgets and circuit breakers), not just “we intend bounded primitives.”
- Clarify **canonicalization contract** vs origin: what is normalized, what is rejected, and how you avoid breaking apps (especially Unicode, double-decode, and ambiguous path semantics).

### Should Consider
- Replace custom distributor with **object-store + pull + pin**; it matches your “data plane offline-safe” philosophy and reduces services.
- Lean on **Envoy/Nginx** for protocol edge cases (HTTP/2/3, weird clients, gRPC) to keep your “interesting” work focused on matching and rollout safety.
- Treat **content-type as attacker-controlled**: route-based inspection policy should be primary, with content-type as a hint, not a gate.
- Add a **replay + diff test harness** (captured requests + multiple origin parsers) as a first-class part of “parsing differential” defense.

### Nice to Have
- A clear **operator runbook**: “at 3am, here’s how to downgrade safely,” including guardrails to prevent permanent `ALLOW` drift.
- Explicit **privacy posture**: redaction rules, structured match metadata schema, retention defaults.
- A small set of **well-defined reason codes** for explainability that remain stable across rule versions.

## What's Working Well
- The data-plane/control-plane split is crisp and operationally sane.
- Streaming inspection with hard caps acknowledges the real DoS vectors (chunking, giant headers, slow parsing).
- Two-tier matching (Aho–Corasick + RE2-only + scoring) is a solid “bounded cost” toolkit.
- Rollout safety (shadow → canary → regional → global with rollback) is treated as part of the product, not an afterthought.
- The doc is honest about trade-offs (availability/predictability over perfect deep inspection), which is exactly what makes a WAF ownable.
```