## Elegance Check

### The Core Insight
Separating **identity proof** (OIDC, short-lived/audience-bound) from **access decisions** (policy + posture, evaluated per request with explicit staleness bounds) is the right “elegant core”—it makes revocation and consistency real without pushing auth into every app.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Access Proxy (Envoy/NGINX) | Single enforcement choke-point, consistent L7 normalization, and the only public entry. |
| OIDC IdP | Best-in-class workforce identity, MFA, device/user directory integration. |
| Policy Engine (OPA/Cedar) | Centralized, versioned, explainable authorization logic and constraints. |
| Device Posture Service | Normalizes many vendor signals into one fast, cacheable “device truth.” |
| mTLS/SPIFFE (or equivalent) | Proves “came through proxy” and blocks bypass paths on the internal network. |
| Audit Log / Event Stream | Forensics + compliance require durable, queryable decision provenance at scale. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Per-request remote PDP call from proxy | Run OPA **in-proxy** (WASM) or as a **local sidecar**, distribute signed bundles | Loses “single live brain,” gains lower latency + fewer failure domains. |
| Separate “Config Store” service | Start with **Postgres** as the config DB (routes/apps/policy metadata), optional LISTEN/NOTIFY for invalidation | Postgres becomes more critical; mitigated via HA + caching. |
| Custom “append-only audit pipeline” implied | Use **Kafka/Kinesis/PubSub** (or managed log pipeline) with schema enforcement | Less custom code; commits you to operating/using a streaming platform. |
| Posture fetched on-demand by proxies | Make posture **event-driven** (device events → materialized state), proxies read from Redis/DB cache | Extra pipeline, but reduces hot-path fanout and vendor API coupling. |
| Signed headers *or* JWT assertion ambiguity | Pick one: **JWT assertion** with strict audience + expiry + key rotation | Slightly more work for apps, but cleaner contract and fewer header-injection pitfalls. |
| “Emergency mode” as a switch | Make it a **policy capability** (break-glass policy bundle + approvals) | Less bespoke control-plane logic; requires careful policy review discipline. |

## Stress Test

### Failure Scenarios

1. **PDP unreachable / slow (network partition, overload)**
   - Design’s answer: partially addressed via “caching,” but hot-path still implies dependency on PDP availability
   - Recommendation: **Strengthen** — keep policy local to the proxy (bundle distribution) so authZ doesn’t fail on PDP liveness; reserve remote calls for rare “step-up”/exception flows.

2. **Posture source is stale for 5 minutes (vendor API outage)**
   - Design’s answer: addressed (bounded staleness, fail closed for high-risk; limited allow for low-risk with audited mode)
   - Recommendation: **Acceptable** — but formalize per-app “staleness budgets,” and ensure posture freshness SLOs drive paging before widespread denies.

3. **Identity/device binding confusion (user authenticates, but device_id is spoofed or not strongly proven)**
   - Design’s answer: not addressed explicitly (device_id appears as an input, but proof mechanism is unclear, especially for browsers)
   - Recommendation: **Strengthen** — require a cryptographic device factor (client cert, platform attestation, or managed agent token) and bind it to the proxy session; otherwise “user+device” collapses into “user says device.”

4. **Policy/config rollback during incident (bad policy locks out everyone)**
   - Design’s answer: addressed (canary + rollback + break glass)
   - Recommendation: **Strengthen** — make rollback instantaneous and *proxy-local* (previous bundle retained); add “diff-based safety rails” (e.g., deny-rate spike thresholds that auto-halt rollout).

5. **Audit pipeline backpressure (audit ingest down, peak 80k RPS)**
   - Design’s answer: “log asynchronously without blocking,” but durability/backpressure behavior isn’t defined
   - Recommendation: **Must clarify** — define local buffering limits and drop/overflow behavior; if you drop, decide what’s acceptable (sample? aggregate?) and how you alert, because audit gaps become a security incident too.

## Recommendations

### Must Fix
- Make **device identity proof** explicit and strong, and bind it to sessions/tokens (browser and API flows differ).
- Remove the hot-path dependency on a **remote PDP** (bundle-distributed local evaluation) or define a concrete degraded mode that doesn’t accidentally fail-open.
- Specify **request normalization + route matching** rules (canonical path, encoded slashes, header canonicalization) to prevent policy bypass and header injection.
- Define **audit durability/backpressure** semantics (buffering, retries, drop policy, and alerting).

### Should Consider
- Prefer a single, boring **Postgres-backed control plane** early (apps/routes/policy metadata), with signed policy bundle distribution to proxies.
- Make posture **event-driven materialization** the default architecture; keep vendor polling out of the request path.
- Decide on one upstream identity propagation contract (JWT assertion recommended) and publish a minimal verification library for apps.

### Nice to Have
- Bind upstream assertions to the connection/request more tightly for replay resistance (very short TTL, optional cnf/DPoP-style binding where needed).
- Add automated “blast radius” controls: per-app canaries, staged rollout by proxy shard/region, and circuit breakers on deny spikes.

## What's Working Well
- The “bounded staleness” framing is clear, operationally measurable, and security-meaningful.
- Treating the proxy as tier-0 with multi-region + rollback drills is the right operational posture.
- Returning constraints (max_session_age, step-up) instead of only allow/deny keeps policy expressive without pushing auth logic into apps.
- The insistence that apps only trust **mTLS from the proxy + a tamper-resistant assertion** prevents the common “pretty VPN” failure mode.