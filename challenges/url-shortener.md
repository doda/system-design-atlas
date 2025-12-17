## Elegance Check

### The Core Insight
Treat redirects as *cacheable content* with bounded staleness (edge TTL derived from `expires_at`), while treating creation/policy/takedown as a strongly consistent control plane (Postgres). That boundary is the right “clever + simple” move.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| CDN Edge | Captures skew and absorbs scanning/flash events; bounded TTL makes correctness tractable. |
| Redirect API | Centralizes correctness (status/expiry/policy → HTTP semantics) and keeps edge configuration dumb. |
| Postgres (primary) | Strong consistency for alias uniqueness, state machine transitions, and auditability. |
| Redis (regional) | Protects Postgres from hot keys and broad read load; enables fast origin responses. |
| Queue + Safety Scanner | Keeps deep inspection off the write path while still enabling post-hoc takedowns with audit trails. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate Admin/Create API + Redirect API | Single service with separate routes + tighter auth middleware | Slightly larger blast radius; simpler deploy/on-call surface. |
| Custom queue (unspecified) | Managed queue (SQS/PubSub) or Postgres-backed job table + `SKIP LOCKED` at this QPS | Managed queue adds vendor dependency; Postgres jobs are simpler but need careful retry/backoff. |
| Version field for cache coherence | Use `updated_at` + optimistic locking (or keep `version` but drop extra cache semantics) | `version` is clearer for debugging; `updated_at` is simpler but easier to mishandle with clock skew. |
| “Purge by surrogate key” as accelerator | Rely primarily on TTL + *targeted* purge only for top N hot links (automated) | Less “instant” feeling; much lower operational burden and fewer purge-failure incidents. |
| Expiration sweeps/partitioning complexity | Partition primarily by `created_at` + index on `expires_at`, and treat “expiration” as computed (`now() > expires_at`) | Fewer moving parts; old rows accumulate unless you add periodic cleanup. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: not explicitly addressed (only cache/TTL described).
   - Recommendation: Strengthen — decide fail-closed vs fail-open. If you must preserve takedown guarantees, fail closed after cache expiry (serve `503`), but consider `stale-if-error` at the CDN only if you’re explicit that it can violate takedown within the window.

2. **Redis is down or partially reachable in one region**
   - Design’s answer: implicit fallback to Postgres on cache miss.
   - Recommendation: Strengthen — add circuit breaking and “brownout” behavior (e.g., short-circuit to CDN-cached errors for obvious scans, reduce DB concurrency, enforce per-IP distinct-code limits more aggressively).

3. **Bad cache headers / 301 browser caching causes “permanent” bad redirects**
   - Design’s answer: caches 301/302 at CDN; does not distinguish browser vs edge caching.
   - Recommendation: Must-fix — avoid user-agent long-lived caching for mutable decisions (expiration/takedown). Common pattern: `Cache-Control: no-store` (or `max-age=0`) for browsers + `Surrogate-Control`/CDN-specific cache headers for edge caching.

4. **Network partition: Redirect API can reach Redis but not Postgres (or vice versa)**
   - Design’s answer: not addressed.
   - Recommendation: Strengthen — define truth hierarchy and safety posture. If Postgres is unavailable, do you honor cached “active” records? If yes, you’re explicitly accepting delayed takedowns; if no, availability drops after TTL.

5. **Safety scanner backlog / delayed verdict reversal**
   - Design’s answer: async scans with takedown writes back to Postgres.
   - Recommendation: Acceptable if you add: idempotent jobs, bounded retry with DLQ, and a “pending review” state for risky destinations (optionally degrade with interstitial until scan completes for new links).

## Recommendations

### Must Fix
- Ensure browsers don’t cache redirects in a way that outlives policy changes: prefer edge-only caching controls (CDN cache headers) and keep client `Cache-Control` conservative.
- Define explicit behavior when Postgres is unavailable (and how it impacts the “≤ 5 minutes” takedown guarantee); document the chosen trade-off.
- Tighten destination URL safety: scheme allowlist (`http/https`), punycode/IDN handling, canonicalization, and block `javascript:`/`data:`; this is a common 3am incident class.

### Should Consider
- Make “bounded staleness” a first-class SLO: measure “takedown-to-effective” and “redirect after expires_at” directly at multiple POPs, and alert on violations.
- Add a hot-key stampede plan that doesn’t require perfect jitter: single-flight in-process + `stale-while-revalidate` at CDN is good, but explicitly cap origin concurrency per code.
- Treat keyspace scanning as a cost-control problem: edge challenge based on *distinct codes per IP/ASN*, not just RPS; keep negative caching consistent (short TTL + vary carefully).

### Nice to Have
- Formalize the link state machine (`active/disabled/blocked/expired`) with transition rules and audit events, so operational actions are reversible and safe.
- Automate targeted purge for the top offenders (e.g., links generating X QPS) so humans aren’t copy-pasting purge commands during incidents.

## What’s Working Well
- The “edge cache + bounded TTL derived from `expires_at`” discipline is a clean, elegant way to make correctness measurable instead of aspirational.
- The design resists the common trap of global strong consistency for reads; it uses workload skew intelligently.
- Versioning + auditable control plane is exactly what abuse/takedown workflows need to avoid mystery behavior and to support appeals.