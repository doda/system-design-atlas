## Elegance Check

### The Core Insight
Separating **event intent (RRULE + tz + exceptions)** from **bounded materialized occurrences** is the right “make it boring” move: it keeps timezone semantics authoritative while making agenda + conflict checks fast and transactional.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Postgres (`occurrence` + GiST + exclusion constraint) | Concurrency-safe “no overlaps” without inventing a lock/coordinator system. |
| Canonical `event_definition` + `event_exception` | Preserves wall-clock intent and supports per-instance overrides correctly. |
| Expander worker | Moves expensive recurrence math off the read path and bounds it to a window. |
| Sync tokens + idempotency | Makes offline/retry behavior deterministic and debuggable. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Dedicated Job Queue | Postgres-backed queue (`FOR UPDATE SKIP LOCKED`) or outbox table + worker | Less infra; careful with noisy neighbors and vacuum/load. |
| Redis for agenda/free-busy cache | Start with Postgres read replicas + app cache keyed by `calendar_version` | Less operational overhead; weaker cross-node cache hit rate. |
| “Persist definition, then materialize” (two-step) | One transaction that updates definition + occurrences + bumps `calendar_version` | Slightly longer transactions; avoids “definition says X, occurrences show Y” windows. |
| Full re-materialize for every edit | Incremental expansion: only recompute affected range, and “extend horizon” jobs | More logic; big win on write amplification. |
| API-layer serialization for hot calendars | Postgres advisory lock per `calendar_id` for write path | Simpler than custom queues; still bottlenecked for celebrity calendars. |

## Stress Test

### Failure Scenarios

1. **Postgres down for 5 minutes**
   - Design's answer: not addressed (mostly focuses on worker lag)
   - Recommendation: Strengthen — define read behavior (stale cache vs fail), write behavior (reject with retry-after), and how sync tokens recover after missed pushes.

2. **Ambiguous local times at DST fall-back (e.g., 01:30 occurs twice)**
   - Design's answer: not addressed
   - Recommendation: Must fix — define a deterministic mapping for “fold” times (pick first/second instance) and encode it in `occurrence_key`/exception identity; otherwise “exceptions drift” can still happen for the repeated hour case.

3. **Bad config / tzdb update changes future offsets**
   - Design's answer: re-materialize pipeline + tzdb_version mismatch detection
   - Recommendation: Strengthen — store `expanded_tzdb_version` per occurrence batch and make reads detect/avoid mixing versions within a window; plan a throttled, resumable reindex keyed by tzid + date ranges.

4. **Worker backlog causes horizon gaps**
   - Design's answer: coverage metrics + prioritized calendars + on-demand expansion beyond horizon (read-only)
   - Recommendation: Acceptable, but clarify “correctness tiers” — what endpoints are allowed to fall back, and how reminders are prevented from firing late/incorrectly (e.g., reminders only from covered horizon).

5. **Traffic 10x + hot shared calendar**
   - Design's answer: isolate onto dedicated shard + serialize writes
   - Recommendation: Strengthen — define a degradation mode (queue writes for that calendar with clear client feedback) and a read strategy (aggressive caching + read replicas) so one calendar can’t cause cascading DB contention.

## Recommendations

### Must Fix
- Fix the **scale math**: with “500 events/calendar” and 60M calendars, the implied definition/occurrence row counts are not Postgres-realistic; either revise assumptions (typical calendars far smaller, only active calendars materialized) or introduce explicit **tiering** (hot window in Postgres, cold history in cheaper storage).
- Specify **transactional consistency** between `event_definition`, `event_exception`, `occurrence`, and the cache key (`calendar_version`) to avoid clients seeing mismatched reads during concurrent edits.
- Define **DST ambiguity** handling and include it in occurrence/exception identity.

### Should Consider
- Make conflict detection explicitly **window-scoped** in the API contract (including what happens when editing something that would create a conflict beyond the horizon).
- Add a `calendar_change_log` (or equivalent) to back sync tokens with a clear retention/compaction story; idempotency keys alone won’t resolve write-write conflicts cleanly.
- Clarify cross-calendar conflict checks: exclusion constraints only protect *within one calendar*; cross-calendar checks need a query-time overlap scan or an aggregated “busy index”.

### Nice to Have
- Separate models for **all-day/floating-time** events vs tz-aware timed events; they behave differently and simplify correctness.
- Make cache invalidation purely version-based (`calendar_version`) and remove ad-hoc keys like `(window,tzid,version)` where possible (compute tz-specific projections from a shared busy set when feasible).

## What's Working Well
- The design is honest about the two real hard parts: **timezone intent** and **recurrence × conflict cross-product**.
- Using **Postgres exclusion constraints** is an elegant “let the DB do concurrency” choice that keeps the system small-team operable.
- The “stable occurrence identity binds to user coordinates” idea is strong; it just needs the DST-ambiguity edge case nailed down.
- Operational notes (caps on expansion, reindex pipeline, horizon monitoring) show good production instincts.