## Elegance Check

### The Core Insight
Separating “boring immutable storage” from “explicit, testable policy” is the right abstraction boundary: it keeps the registry simple while putting the real complexity (compatibility meaning, baseline choice, ownership) into a versioned control plane that CI can enforce deterministically.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| `schemactl` (CLI/CI action) | Gives teams fast feedback and a consistent workflow; keeps schema checks close to PRs. |
| Registry API | Central authority for policy + baseline selection + audit; prevents per-repo drift and “it passed locally”. |
| Postgres (SoT) | Transactions + constraints + audit queries fit governance; 300k versions is well within comfort. |
| Compatibility engine (Avro/Protobuf aware) | Text diffs are wrong; semantic evolution rules are the product. |
| Audit log (policy + publish decisions) | Makes governance reversible and defensible; critical for break-glass. |
| Runtime read path (by ID/fingerprint) | Consumers need a stable, cacheable lookup to decode data safely. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom registry from scratch | Adopt/extend an existing registry (Confluent Schema Registry, Apicurio, Redpanda, AWS Glue) and focus on policy/CI UX | Less control over policy model and break-glass semantics; integration constraints. |
| Redis + CDN cache tier | Start with HTTP caching + CDN only for immutable `byId/byFingerprint`; add Redis only if proven necessary | Slightly more work in client caching; less “latest” convenience without an origin hit. |
| “latestCompatible” runtime endpoint | Prefer immutable IDs embedded in messages (or schema ID headers) and use registry only for ID→schema | Requires producer changes and conventions; less magic, more explicit contracts. |
| Custom policy logic embedded in service | Policy-as-code (OPA/Rego or Cedar) with versioned bundles | Adds a dependency and learning curve; can be overkill for a small team. |
| Break-glass publishes in-place + “epoch” | Make break-glass require a *new subject* (or mandated `-v2`/`epoch=2` naming) rather than in-place incompatibility | More subjects to manage; much safer operationally and culturally. |
| Protobuf canonicalization/compilation inside CLI | Centralize compilation in the registry (containerized, pinned `protoc`, pinned include roots) and make CLI a thin submitter | More server CPU; but eliminates “works on my machine” descriptor differences. |

## Stress Test

### Failure Scenarios

1. **Postgres down for 5 minutes**
   - Design's answer: CI stalls; allow `check` via short TTL read-only cache; disallow `publish`.
   - Recommendation: **Strengthen** — make the degraded `check` mode an explicit *signed snapshot* (subject→baselineVersion+policyVersion+schema) so CI decisions remain deterministic and auditable during outages.

2. **Two teams/PRs publish concurrently to the same subject**
   - Design's answer: not addressed.
   - Recommendation: **Must fix** — add per-subject serialization (Postgres advisory lock or `SELECT … FOR UPDATE` on a subject row) + idempotency keys for `publish` to prevent version races and “last writer wins” surprises.

3. **Network partition: CI can reach cache/CDN but not the registry**
   - Design's answer: CI reads strongly consistent from Postgres; runtime reads cacheable.
   - Recommendation: **Strengthen** — document a hard rule: CI must never use CDN “latest”; only use registry snapshot/SoT. If registry is unreachable, CI either fails closed or uses the signed snapshot path.

4. **Bad policy change blocks the org (or silently loosens rules)**
   - Design's answer: versioned/rollbackable policy + policy test endpoint + fixtures.
   - Recommendation: **Acceptable but sharpen** — require “policy rollout” as a two-phase activation (draft → canary subjects/environments → activate) and always record `policyVersionUsed` in every check/publish audit row.

5. **Compatibility checker bug (false pass) ships a breaking change**
   - Design's answer: not addressed.
   - Recommendation: **Strengthen** — treat checker releases like a compiler: pin checker version in CI, run golden fixture suites per release, and store the checker build/version in audit logs so you can answer “why did this pass then?”.

## Recommendations

### Must Fix
- Define the precise semantics of `latestCompatible`: compatible with *which* deployed readers/writers (often multiple consumer versions exist); consider dropping it in favor of immutable IDs + explicit baselines.
- Add concurrency + idempotency controls for `publish` (per-subject locking, request idempotency keys, monotonic version assignment).
- Make Protobuf descriptor generation fully deterministic (pinned `protoc`, pinned imports, no ambient filesystem/state); otherwise fingerprints will drift across environments.
- Constrain break-glass so it can’t create silent partial outages: strongly prefer “new subject / new epoch name” over in-place incompatible publishes.

### Should Consider
- Start with Postgres + CDN (immutable endpoints) and defer Redis until measurements demand it; reduce moving parts for a small platform team.
- Use Postgres row-level security or a single, simple authz model (OIDC→team claims→namespace) to keep authorization understandable at 3am.
- Add “promotion” mechanics (dev→staging→prod) so the baseline choice is explicit and reproducible, not just “latest in prod”.

### Nice to Have
- A small UI/portal for subject ownership, policy, recent publishes, and break-glass history (reduces support load).
- Consumer-impact notifications wired to ownership (Slack/email hooks per subject) with clear “action required” thresholds.
- A “schema diff explainer” library shared between CLI and registry so reports are identical everywhere.

## What's Working Well
- Clear separation of concerns (storage vs policy) and a realistic focus on auditability and small-team operability.
- Good instinct to keep CI strongly consistent while letting runtime reads be cache-heavy.
- Ownership-as-a-first-class concept is a high-leverage governance simplifier.
- The doc is honest about trade-offs and already anticipates the two biggest cultural failure modes: bypass pressure and human bottlenecks.