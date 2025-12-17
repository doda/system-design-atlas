## Elegance Check

### The Core Insight
Treat the share link as a *capability pointer to server-side policy* and force all bytes through a single “policy meets exfiltration” choke point (Download Gateway), so revocation/DLP/watermarking remain enforceable at download time.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Download Gateway | The only reliable place to re-check revocation/DLP at byte time and ensure “never serve original.” |
| Postgres | Strong consistency for “allowed right now,” counters (`max_downloads`), and state machines (DLP + share policy). |
| Object Store + KMS | Cheap durable blob storage + principled separation of storage vs decrypt authority. |
| DLP Scanner | Turns “scan latency” into an explicit pipeline with measurable SLOs and fail-closed semantics. |
| Watermark Worker | Offloads CPU-heavy rendering and enables controlled backpressure (202 prepare flow). |
| Audit Log | Forensics-grade append-only record; critical for security systems that will be litigated during incidents. |
| Queue | Decouples variable-latency work (scan/render) from request path and supports spike absorption. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Gateway streams large derivatives to clients | After policy check, issue *very short-lived* pre-signed URLs **only for already-watermarked derivatives** (or 302 to CDN/origin) | Preserves revocation semantics (since issuance is per-request), but adds complexity around redirect behavior, range requests, and logging. |
| Separate queue just for jobs | Start with Postgres-backed jobs (e.g., `SKIP LOCKED`) for watermark + DLP if team is small | Might hit throughput/operability limits sooner at 20k/s peaks; managed queue still likely right long-term. |
| Audit “Kafka → immutable store” always-on | Dual-write: synchronous minimal receipt in Postgres + async ship to WORM store | Receipt is not WORM; you’re explicitly accepting a small window where immutability is delayed but availability improves. |
| Per-download watermark includes timestamp + cacheable derivative key | Use a watermark that’s stable for a bounded window (e.g., per day/session) or drop timestamp from watermark and rely on audit log timestamp | Either reduces attribution granularity on the artifact or reduces cache hit rate. |
| OTP recipient binding as email hash | Use `HMAC(server_secret, normalized_email)` and store only the HMAC | Slight key-management burden, but avoids offline dictionary/rainbow issues and normalizes identity safely. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: not addressed (but gateway depends on DB lookup for every download)
   - Recommendation: **Strengthen** — define explicit behavior. Options: (a) fail closed for external shares (likely required), (b) allow only requests with a fresh cached policy snapshot + fast revocation invalidation (LISTEN/NOTIFY → gateway cache) with very short TTL, (c) multi-AZ PG + read replicas + connection pooling as the primary mitigation.

2. **Audit pipeline (Kafka/WORM writer) is degraded or unavailable**
   - Design’s answer: implied “record immutably for every access attempt,” but no availability stance
   - Recommendation: **Must decide** — either fail closed (security-pure but can create outage) or buffer durably (local disk/WAL/queue) and accept at-least-once + delayed immutability. Document the choice and the recovery/runbook.

3. **Watermark fleet overload during a spike (20k/s)**
   - Design’s answer: backpressure via 202 prepare flow; cap synchronous watermarking to small files
   - Recommendation: **Strengthen** — add admission control and anti-amplification: idempotent prepare requests, bounded polling with `Retry-After`, per-tenant fairness, and a “single-flight” dedupe so 1,000 clients don’t enqueue 1,000 identical renders.

4. **Bad config/rotation breaks decryption or watermarking**
   - Design’s answer: “rotate secrets/templates regularly” + “serve original is Sev0”
   - Recommendation: **Strengthen** — require staged rollout with canaries that actually perform a full download (token→policy→decrypt→watermark→stream) and automatic rollback on error budget burn. Also version watermark templates and keep old renderers available until derivatives expire.

5. **Network partition between gateway and object store / KMS**
   - Design’s answer: not addressed
   - Recommendation: **Acceptable if explicit** — likely fail closed (no bytes) is correct, but add clear user-facing error modes and internal alerts; consider regional affinity so gateway/worker/KMS are co-located to reduce blast radius.

## Recommendations

### Must Fix
- Resolve the **watermark caching inconsistency**: you say the watermark includes a timestamp, but `wm_key` doesn’t—either include a bounded-time component in the key or remove timestamp from the artifact and keep time in the audit record.
- Specify **audit unavailability behavior** (fail closed vs durable buffer). Right now this is a hidden, high-stakes policy decision.
- Treat **token leakage in logs** as a first-class risk: gateway/access logs must redact tokens (path/query), and headers like `Referrer-Policy` don’t protect your own logs.

### Should Consider
- Use **short-lived pre-signed URLs for derivatives only** to offload bandwidth while keeping “policy check at request time” intact.
- Add a **revocation-aware gateway cache** (Redis or in-memory) fed by Postgres `LISTEN/NOTIFY` for revokes/expiry changes to reduce DB load without weakening “hard revocation.”
- Make `max_downloads` and OTP binding **race-proof** with a single atomic DB update/transaction pattern.

### Nice to Have
- Define a crisp **state model for shares vs doc versions** (what happens to existing shares when a new doc version is uploaded and scan resets?).
- Add explicit **runbooks** for “DLP vendor outage,” “watermark renderer bug,” and “incident-wide derivative TTL change,” with clear blast-radius controls.

## What’s Working Well
- The “download-time authorization” stance is clean and honest; it avoids the common pre-signed URL revocation trap.
- DLP as an explicit state machine with fail-closed semantics is operationally legible and hard to accidentally bypass.
- The watermark approach avoids storage sprawl while keeping the security invariant (“never serve original”) uncompromised.
- You explicitly anticipate human/ops pressure (bypass requests) and propose controlled override + justification, which is realistic.