## Elegance Check

### The Core Insight
Separating **candidate discovery** (approx, bounded state) from **surge scoring** (exact, windowed) is the right “make it tractable” move—and it cleanly focuses complexity where it buys quality.

### Components That Earn Their Place
| Component | Why It’s Necessary |
|---|---|
| Ingest API | Centralizes normalization/abuse throttles; keeps the stream job from becoming the first line of defense. |
| Kafka | Replayable source of truth; makes “recomputable” analytics operationally sane. |
| Flink + RocksDB state | Event-time correctness + large keyed state with checkpoints; good fit for bounded-lateness sliding logic. |
| Heavy-hitter + candidate registry | The one genuinely custom piece that prevents state explosion while keeping recall acceptable. |
| Redis (serving) | Cheap low-latency reads for “top trends”; keeps API boring and fast. |
| Object store (checkpoints/savepoints) | Fast recovery + safer deploys; avoids “state is gone” incidents. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---|---|---|
| Per-key ring buffers for exact sliding windows | Replace baseline with **EMA/decay** (track short EMA + long EMA per key) | Less “exact window” explainability; tuning decay constants becomes critical, but state drops to O(1) per key (no buffers). |
| Redis as the serving store | Emit ranked lists to a **Kafka compacted topic**; API keeps an in-memory cache (optionally with local persistence) | API becomes stateful and needs replay handling; but you may remove Redis ops entirely for a small team. |
| Space-Saving stored/updated via RocksDB per event | Add **local pre-aggregation** (per task: map keyword→count for 1–2s, then flush) | Slight latency/complexity increase; drastically reduces RocksDB write amplification and GC/compaction pressure. |
| Candidate TTL registry inside Flink | Push candidates into **Redis SET with TTL** (or compacted topic) and have scoring stage subscribe | Cross-system coupling and eventual consistency; but can simplify Flink state and improve operability if state growth is a pain point. |
| One Flink job doing discovery + scoring | Split into **two jobs** (discovery → candidate topic; scoring consumes candidates) | More moving parts and end-to-end latency; but isolates hotspots and makes scaling knobs clearer. |

## Stress Test

### Failure Scenarios

1. **Redis is down or partially unavailable**
   - Design’s answer: “Redis is disposable; Flink repopulates from Kafka”
   - Recommendation: Strengthen — specify API behavior (serve stale from local cache? return empty?), and make writes idempotent + batched; ensure Redis key TTLs don’t cause mass-expiry stampedes on recovery.

2. **Flink restart + replay causes duplicate counting (at-least-once)**
   - Design’s answer: not addressed (checkpointing mentioned, but semantics aren’t)
   - Recommendation: Must fix — trending is very sensitive to brief spikes; define **exactly-once** requirement (Kafka + Flink EOS) or explicitly accept at-least-once and add bounded dedupe (e.g., per-partition sequence, event-id Bloom/TTL for 30–60s) to prevent “replay = trend”.

3. **Object store outage during checkpoint (5+ minutes)**
   - Design’s answer: “checkpoint health is canary”; no explicit degrade mode
   - Recommendation: Strengthen — define what happens when checkpoints fail (job fails vs continues), and have an operator playbook: pause/slow sources, reduce candidate N, extend checkpoint interval, or temporarily switch to in-memory state knowing you may lose correctness.

4. **Hot key / adversarial keyword attacks (one term dominates, or spam creates many near-duplicates)**
   - Design’s answer: mentions hot partitions + abuse throttles, but not token-level adversarial behavior
   - Recommendation: Strengthen — add normalization rules (casefolding, Unicode confusables, max token length), per-user/per-IP contribution caps, and consider “unique users” support (approx via HLL) for promotion so one botnet doesn’t manufacture trends with low diversity.

5. **10× traffic spike + slow component (RocksDB compaction / backpressure)**
   - Design’s answer: scale slots; reduce candidate N; increase evaluation interval
   - Recommendation: Acceptable, with one addition — define a **graceful degradation ladder** (drop 1h window first, then reduce scopes, then reduce candidate TTL) and ensure you can flip these via runtime config (not redeploy).

## Recommendations

### Must Fix
- Define processing guarantees: **exactly-once vs at-least-once**, and how duplicates affect scores.
- Clarify candidate discovery semantics: “per 10s slice” can be misread as “many summaries” (state blow-up); specify whether it’s a resettable summary, a rolling window, or a decayed counter.
- Define baseline rigorously per window (especially 1h): “preceding window” will over-report diurnal effects; consider long-term baseline (EMA or day-over-day bucket).
- Put hard caps on “scope explosion” (locales × windows × candidates) with explicit memory math and eviction rules.
- Specify late-event policy beyond 30s (drop? count but don’t re-rank?); align this with “stable results” requirements.

### Should Consider
- Local pre-aggregation to cut RocksDB write amplification (often the real limiter at 200k/s).
- A diversity-aware promotion signal (unique users) so “one actor” spikes don’t dominate.
- Make tuning knobs dynamic and safe: config in a dedicated topic + validation + staged rollout (bad config is a top-3 real incident cause).

### Nice to Have
- Explainability endpoint: return `c_now`, `c_base`, support, and a short reason (“spike in last 2m vs prior 5m”) for debugging/product trust.
- Shadow/scoring A/B: run two score formulas in parallel and compare offline to avoid “score tweaks break the product”.
- Output versioning: include a `model_version` / `config_version` in emitted trend lists for auditability.

## What’s Working Well
- The two-stage approach is genuinely elegant: it attacks the *state explosion* root cause without pretending popularity == trending.
- You explicitly budget complexity (event time, watermarks, hysteresis) only where it improves quality and stability.
- Operational honesty is strong: Redis as cache, Kafka as truth, checkpoint health as a first-class signal.
- The design already anticipates the real pain points (candidate churn, hot partitions) and offers practical mitigations.