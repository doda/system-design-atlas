## Elegance Check

### The Core Insight
Treat *alerts as immutable facts* and derive *incident state* via deterministic projection, so retries/outages become “replayable” engineering problems instead of paging bugs. The second key insight is separating **alert identity** (fingerprint) from **human work identity** (incident key), making grouping a deliberate routing decision.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Ingest API | Enforces tenant/auth boundaries and normalizes heterogeneous producers into one canonical event shape. |
| Event Log | Absorbs spikes during outages, provides backpressure, and gives a replay boundary for correctness + audit. |
| Processor | Centralizes the “one incident state machine” logic and makes dedup/silence/escalation deterministic under retries. |
| Incident DB (Postgres) | Strong constraints + transactions for leases/uniqueness, plus rich queryability for “why did/didn’t page?”. |
| Notifier | Contains provider-specific rate-limit/backoff/idempotency behavior so the core state machine stays clean. |
| UI & API | Control plane for humans; without it, silences/ack/auditability are aspirational. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Separate `Config DB` + `Incident DB` | Single Postgres cluster, separate schemas + connection pools + (optional) read replicas | Less isolation, but simpler ops; still protects hot-path via pool limits and query discipline. |
| Kafka as default event log | Postgres “event table” + `SKIP LOCKED` pollers (or LISTEN/NOTIFY) for smaller deployments | Likely won’t meet 200k/min peak comfortably; Kafka earns its place at your stated scale. |
| Processor directly deciding and triggering notifications | Emit `NotificationEvent`s (outbox) and have Notifier consume them | Adds an internal event type, but removes the hardest failure mode: “state committed but notification lost”. |
| Leases via DB locks per `IncidentKey` | Advisory locks **plus** fencing token (monotonic `incident_version`) | Slightly more bookkeeping, but makes split-brain and failover behavior explicit and safer. |
| `NotificationId` includes `template_version` | Make idempotency reflect *intent* (`incident_id + escalation_step + channel + provider`) and track “content version” separately | You avoid accidental re-page on deploy; you lose automatic “re-notify because template changed” (which is usually good). |
| Custom routing/silence engine | Reuse matchers semantics from Prometheus Alertmanager (label matchers, silence model) even if you don’t reuse the whole service | Less bespoke behavior to explain/debug; you inherit some of Alertmanager’s constraints/opinions. |

## Stress Test

### Failure Scenarios

1. **Postgres down for 5 minutes**
   - Design’s answer: partially addressed (config cache + TTL, but incident DB outage isn’t discussed)
   - Recommendation: **Strengthen**
   - Add: explicit behavior when incident DB is unavailable (ingest continues to event log; processor halts; backlog drains on recovery). Define whether UI shows “read-only degraded”. Ensure no notifications are sent without a committed incident transition.

2. **Kafka (event log) degraded or unavailable**
   - Design’s answer: not addressed
   - Recommendation: **Strengthen**
   - Add: ingest behavior (429 + client retry guidance), local disk buffer yes/no, and an SLO for “accepted events”. If Kafka is the replay boundary, make “we drop vs we block” an explicit policy per tenant/severity.

3. **Network partition: Processor can write Postgres but Notifier can’t reach providers**
   - Design’s answer: partially addressed (rate limits, retries)
   - Recommendation: **Strengthen**
   - Add: “notification intent” persistence (outbox or `NotificationEvent` log) so you don’t lose pages; and provider failure policy (retry with jitter, max delay, escalation timing semantics when sends are delayed).

4. **Bad config deploy (routing rules / silences / schedules)**
   - Design’s answer: partially addressed (“last-known-good”, “fail safe for paging”, block new escalation if unknown)
   - Recommendation: **Strengthen**
   - Add: config versioning + staged rollout + validation/dry-run (“show who would be paged for the last 1h of incidents”). Also clarify the “safe” policy: freezing escalation can cause missed pages; paging-on-unknown can cause storms—pick per severity/tenant with explicit defaults.

5. **Out-of-order / duplicated events across sources**
   - Design’s answer: implied (idempotency + dedup window), but ordering semantics aren’t explicit
   - Recommendation: **Strengthen**
   - Add: per-incident monotonic `incident_version` (or transition sequence) and define how “resolve then open” is handled if events arrive late. Make server-received timestamp authoritative (you note time skew—good); carry producer time as metadata only.

## Recommendations

### Must Fix
- Define a **transactional handoff** between “incident transition decided” and “notification send happens” (DB outbox or `NotificationEvent` stream). Without this, you’ll eventually miss pages during partial failures.
- Make **ordering and fencing** explicit: add `incident_version` and require writes/notifications to reference the expected version to prevent split-brain “both thought they owned the incident”.
- Specify **incident resolution semantics** (clear signal vs timeout, per alert type) so “open→resolved→reopen” isn’t arbitrary; this impacts MTTR, paging fairness, and escalation cancellation.

### Should Consider
- Collapse to **one Postgres cluster** (two schemas + separate pools) unless you have hard evidence config queries will starve incident writes; keep the “split” as a scaling option.
- Align silences/routing matcher semantics with an existing model (Alertmanager-like matchers) to reduce bespoke edge cases and improve operator intuition.
- Revisit `NotificationId` to avoid **deploy-triggered repages**; track message/template version for auditing without changing idempotency.

### Nice to Have
- “**Why didn’t I get paged?**” should include a first-class timeline: matched silence, matched route, escalation suppressed due to config unknown, provider failure delays.
- Built-in **config diff + replay simulator**: apply candidate config to recent incidents and show expected routing/escalations before rollout.
- Explicit per-tenant **load shedding policy**: which signals degrade first (email/webhook) while paging remains protected.

## What's Working Well
- The alert/incident identity split is the right abstraction; it’s the difference between “noisy alerts” and “stable human work”.
- Treating providers as unreliable/rate-limited and pushing idempotency to the boundary is pragmatic and production-shaped.
- Calling out fingerprint versioning and server-side timestamps shows you’re designing for long-lived correctness, not demos.
- The control-plane/data-plane separation is clean and makes the “interesting part” (incident state machine) easier to reason about and own.