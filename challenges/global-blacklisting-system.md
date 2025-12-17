## Elegance Check

### The Core Insight
Treating “block decisions” as a signed, versioned, globally replicated artifact stream (instead of a globally queried DB) is the right abstraction: it makes the edge hot path deterministic, bounded, and auditable, while keeping correctness/safety centralized.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Policy Engine | Single place for scoring, allowlists, provenance, sanity checks, and producing a canonical “truth” with rollback semantics. |
| Signed Artifacts (snapshot + delta) | Deterministic edge enforcement, fast cold start/catch-up, and a strong “what was active when” audit trail. |
| Artifact Store (object store semantics) | Decouples “publish” from “fetch,” enables caching, and gives PoPs a reliable recovery path after partitions. |
| PoP Enforcers (in-memory matcher) | Keeps the request path local and predictable; isolates data structure complexity from gateways. |
| Ingest API w/ quotas + validation | Prevents poisoned inputs and operational mistakes from becoming global incidents. |
| Version gating + rollback-as-next-version | One operational lever that works under stress; avoids “delete everywhere” coordination failures. |

### Simplification Opportunities
| Current | Simper Alternative | Trade-off |
|---------|---------------------|-----------|
| Kafka as the global distribution spine to edge | Object store + CDN for artifacts, plus a lightweight notification channel (SNS/SQS/PubSub/WebSocket fanout) carrying only `{version, manifest_hash}` | You lose “one system does everything”; you gain fewer moving parts and better cache economics. |
| Regional Distributors maintaining long-lived PoP connections | Use CDN/edge caching + long-polling (or server-sent events) to a small notification service; PoPs fetch artifacts directly from nearest cache | Slightly higher fetch latency in some cases; much simpler ops than bespoke connection management. |
| Custom secure update protocol (pinned key + version monotonicity) | Adopt **TUF** (The Update Framework) concepts: signed manifests, key roles, rotation, threshold signatures, rollback/freeze protections | Some upfront complexity, but it’s “standard hardening” instead of bespoke crypto + edge cases. |
| Always-on prefilter (Bloom/Xor) + exact structure | Start with exact-only (radix trie + hash set) and add prefilter only if profiling shows CPU issues at p99 under realistic cache pressure | Risk of higher CPU; but avoids dual-structure complexity and correctness pitfalls early. |
| Single global artifact for all PoPs | Per-region/per-product “views” (still signed) so PoPs load only what they need (e.g., IP-only at L4, domain-only at L7, jurisdictional sets) | More build variants; big win in memory, rollout blast radius, and operational clarity. |
| Append-only events at the same granularity as inputs | Micro-batching in the Policy Engine (e.g., 200–500ms windows) to amortize rebuild costs and reduce version churn during 10k/s bursts | Slightly slower “block now” unless emergency bypass exists; major stability improvement during attack spikes. |

## Stress Test

### Failure Scenarios
1. **Control plane (Policy Engine) down for 5 minutes**
   - Design’s answer: PoPs keep enforcing last-known-good; replay after recovery via log/artifacts.
   - Recommendation: Strengthen — define explicit SLOs and behavior: max “staleness” tolerated per risk class, and an operator-visible “stale mode” at PoPs.

2. **Artifact signing key compromised (or suspected compromise)**
   - Design’s answer: pinned public key, offline/HSM-backed signing.
   - Recommendation: Strengthen — spell out key rotation and revocation (new root keys, threshold/multi-sig for “break glass,” rapid invalidation of compromised keys). TUF-style roles help a lot here.

3. **Network partition: PoPs split-brain across versions**
   - Design’s answer: version monotonicity; PoPs accept only higher versions; stale enforcement continues.
   - Recommendation: Acceptable, but add “max version skew” dashboards and a playbook: when to halt rollout, when to force snapshot fetch, and when to freeze publishing.

4. **Update storm (10k updates/s) causes artifact rebuild thrash**
   - Design’s answer: not explicitly addressed (mentions deltas/snapshots, bounded catch-up).
   - Recommendation: Strengthen — add batching + backpressure at publish time, plus “attack-mode” short-TTL artifacts that can be compacted/expired aggressively.

5. **Bad rule or bad normalization blocks a major customer globally**
   - Design’s answer: anomaly detection + rollback by publishing N+1.
   - Recommendation: Strengthen — ensure rollback is fast even if publishing is impaired: keep a pre-signed “empty/allow-only” emergency artifact, and consider per-customer override artifacts that can be published independently of the global stream.

## Recommendations

### Must Fix
- Define secure update hardening beyond “signature + monotonic version”: key rotation/revocation, freeze/rollback attacks, and distributor compromise model (TUF/Uptane patterns fit well).
- Specify artifact lifecycle semantics: TTL/expiry, compaction, and how removals work under partitions (avoid “zombie blocks” that never age out).
- Add explicit publish-side backpressure: batching, rate limits, and emergency lanes so “block now” doesn’t imply “rebuild everything now” at 10k/s.

### Should Consider
- Replace or drastically simplify **Regional Distributors** using CDN/object-store caching + a tiny notify plane; keep only what’s truly needed for seconds-level convergence.
- Split artifacts by scope (subject type / region / product / jurisdiction) to reduce memory and blast radius while keeping the same signing/verifiability story.
- Make the build reproducible and content-addressed: publish `{manifest, artifact_hashes}` and sign the manifest; PoPs verify hashes for integrity and easier debugging.

### Nice to Have
- Public Suffix List-aware domain handling and explicit normalization rules (punycode, trailing dots, wildcard semantics), because domain mistakes are a common outage source.
- “Prove it” tooling: given a request sample + artifact version, deterministically explain the match (`rule_id`, provenance, and the exact matcher path), to speed up 3am incidents.

## What's Working Well
- The separation of a strongly consistent control plane from an eventually consistent enforcement plane is clean and operationally sane.
- Versioned, signed artifacts + “rollback by publishing” is an elegant, unified mechanism that scales operationally.
- The design is honest about the hot-path reality (cache behavior, GC pauses) and pushes complexity out of the request path.
- The failure mode thinking (staleness, poisoned feeds, canary gating) is pointed at the right real-world risks.