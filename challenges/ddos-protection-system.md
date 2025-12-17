## Elegance Check

### The Core Insight
Keep the edge datapath deterministic and dependency-light (local-only decisions + stateless challenges), while pushing “discover new badness” into an async loop that feeds back coarse, stable policies.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Anycast Edge POP | Contains blast radius; keeps mitigation close to ingress; avoids regional choke points. |
| L3/4 Filter | Preserves L7 CPU/TLS budget by cheaply killing obvious volumetric garbage first. |
| L7 Proxy | Normalizes signals, terminates TLS, enforces HTTP semantics; needed for L7 floods. |
| Risk & Policy | Provides a single, fast decision point for progressive friction with local state. |
| Telemetry Pipeline | Lets you debug/iterate without coupling analytics to the hot path. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “Challenge Service” as a distinct component | Make challenge mint/verify a module inside the L7 proxy (Envoy/Nginx filter) with a small shared library for token format | Less “service” overhead; tighter coupling to proxy release cadence. |
| Custom policy distribution implied | Use `etcd`/Consul (or a managed config plane) for signed policy bundles + per-POP caching | Adds dependency to config store, but only on the cold path; improves auditability/rollbacks. |
| Bespoke L7 proxy | Start with Envoy + WASM/Lua/ext_authz for policy/challenge decisions | Faster time-to-production; some performance/footprint overhead vs fully custom datapath. |
| Analytics store + pattern mining from scratch | Use Kafka + ClickHouse (or BigQuery) + a small “rule compiler” job | Less custom infra; pushes you toward batch/near-real-time rather than “real-time ML”. |
| “Line rate” claim at L3/4 in software | Use XDP/eBPF (or DPDK) for first-pass filters + conntrack protection | More specialized ops; materially improves PPS headroom and survivability. |
| Client identity = IP prefix + fingerprint | Prefer a tiered identity: `account/api-key` → `session` → `device attestation` → `prefix+fp` | More product integration work; dramatically reduces NAT collateral damage. |

## Stress Test

### Failure Scenarios

1. **Control plane down for 5–30 minutes (policies can’t update)**
   - Design’s answer: addressed (last-known-good, local lockdown).
   - Recommendation: Strengthen — require signed policy bundles with explicit expiry + rollback pointer; define what happens when LKG expires (continue, degrade, or fail-closed) per tenant.

2. **Anycast re-route / client hits a different POP mid-challenge**
   - Design’s answer: not addressed (tokens keyed by `k_pop` implies POP stickiness).
   - Recommendation: Must fix — use a globally verifiable keyring (`kid` + rotated HMAC keys) or a two-level scheme (global verify + optional POP-local hardening). Otherwise you’ll self-amplify friction during BGP shifts.

3. **Replay and sharing of solved challenges within TTL**
   - Design’s answer: partially addressed (short TTL + bind to `client_id`).
   - Recommendation: Strengthen — explicitly accept “bounded replay” as a trade-off, but reduce impact: bind token to a narrow scope (hostname + path class), include issuance timestamp bucket, and cap bypass value (e.g., token only upgrades you one step: from PoW→rate-limit, not PoW→full allow).

4. **Slow-not-dead dependencies (origin latency spike, telemetry backpressure, CPU saturation)**
   - Design’s answer: partially addressed (sampling/counter-only mode; difficulty tied to saturation).
   - Recommendation: Strengthen — add hysteresis/rate-of-change guards to avoid control-loop oscillation; define hard circuit breakers (e.g., “TLS accept rate cap”, “early 503 with Retry-After”, “disable expensive normalization features”).

5. **Bad config/rule rollout blocks legitimate traffic at scale**
   - Design’s answer: addressed (shadow mode; operator controls).
   - Recommendation: Strengthen — require canary-by-POP + per-tenant staged rollout + automatic abort on guardrail metrics (auth success rate, checkout starts, API 2xx) and keep a “known-good policy” pinned locally for instant revert.

## Recommendations

### Must Fix
- Clarify key management for stateless tokens: rotation, `kid`, clock skew, POP-to-POP verification, and blast radius if a POP key leaks.
- Resolve POP mobility: challenges must survive anycast/BGP shifts or you’ll create friction storms during route churn.
- Define the control loop stability: hysteresis, max step-change per interval, and “safe mode” defaults under noisy signals.

### Should Consider
- Collapse “Challenge Service” into the L7 proxy to reduce moving parts; keep only a thin offline “challenge config” publisher if needed.
- Make “identity” explicitly tiered to reduce NAT harm and improve API ergonomics (API keys and authenticated sessions should dominate scoring).
- Be honest about “line rate”: specify what runs in NIC/kernel (XDP) vs user space, and what pps/rps each tier is sized for.

### Nice to Have
- A documented decision-reason taxonomy (stable codes) plus a lightweight per-request debug header in shadow/canary mode.
- A “degraded mode matrix” (what features disable at 60/80/95% CPU, and what the user sees).
- Explicit tenant isolation: per-customer policy budgets, rate-limit partitions, and “noisy neighbor” containment.

## What’s Working Well
- Clear separation of hot-path mitigation from cold-path analytics; that’s the right survivability principle.
- Progressive friction framing as capacity control (not “detect perfectly”) is operationally pragmatic.
- Local-first operation with last-known-good policies and aggressive telemetry shedding shows good attack realism.
- The trade-offs are stated honestly (especially around NAT/shared networks and explainability limits).