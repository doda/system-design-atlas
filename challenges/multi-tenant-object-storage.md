## Elegance Check

### The Core Insight
Treat *data* as immutable, content-addressed chunks and make *metadata transitions* the only source of truth; lifecycle + versioning + CRR become deterministic consumers of the same ordered history instead of ad-hoc mutators.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|---------------------|
| Metadata DB | Only place that can safely define “latest”, versioning semantics, multipart state, and idempotency boundaries. |
| EC Storage Nodes | Durability/cost hinge; local disks + EC + repair are the real differentiator at PB scale. |
| Ingest Router | Hides EC fanout, streaming, retries, and consistent commit protocol from clients/API. |
| CRR Replicator | Encapsulates cross-region idempotent apply and backfill logic; keeps API path clean. |
| Auth & KMS | Multi-tenant isolation and encryption are core product requirements, not a bolt-on. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Custom “per-bucket ordered change log” service | Transactional outbox table in the Metadata DB + CDC (e.g., logical decoding) or Kafka topic | DB/CDC operational coupling; Kafka adds infra but removes bespoke log. |
| Bucket-wide total ordering for all keys | Partition ordering by `(bucket_id, key_hash/prefix)` or per-object-key streams | Less global determinism; more care to preserve S3 semantics (especially LIST/replication expectations). |
| “Re-key/mark referenced after commit” finalization step | Write shards under final `chunk_id` immediately (hash-as-you-stream), or store a durable alias map `(upload_id -> chunk_id)` that reads can follow | Harder streaming implementation or slightly more metadata; avoids split-brain between manifest and node-local state. |
| Lifecycle “read bucket stream” as primary driver | DB-driven due-index (next-action timestamp) + emit events as the output | Loses the “single mental model”; gains simpler scheduling and bounded scanning cost. |
| Build from scratch | Adopt MinIO/Ceph for data plane; keep your metadata/event model as a control plane overlay | Constrains custom semantics; faster time-to-prod and battle-tested repair/placement. |

## Stress Test

### Failure Scenarios
1. **Metadata DB down for 5 minutes**
   - Design’s answer: not addressed (implied “metadata is strongly consistent”)
   - Recommendation: Strengthen (define behavior: PUT/DELETE fail fast; GET for already-committed objects can be served only if you have a safe read-through cache of *metadata*, not just data).

2. **Router writes data, then can’t commit metadata (timeout / partition)**
   - Design’s answer: “uncommitted shards GC by age”
   - Recommendation: Strengthen (ensure no state where metadata references shards that are only in `upload_id` space; either make reads follow an alias, or make “finalize” part of the durable commit invariants).

3. **Slow storage nodes (not failing) cause cascading tail latency**
   - Design’s answer: degraded reads reconstruct; throttle repair
   - Recommendation: Strengthen (add explicit per-node timeouts, hedged reads, and admission control so repairs + LIST spikes don’t starve foreground GET/PUT).

4. **Bad lifecycle rule deletes/archives too aggressively**
   - Design’s answer: lifecycle emits version events (correctness), but no safety story
   - Recommendation: Strengthen (require “dry-run” previews, staged rollout, and a kill-switch; make lifecycle actions reversible where possible, and log operator attribution).

5. **10x LIST-heavy spike**
   - Design’s answer: “push LIST acceleration into a dedicated prefix index at 10x”
   - Recommendation: Acceptable if explicitly scoped, but be honest: bucket-wide ordering + strong consistency can become the bottleneck; define LIST consistency guarantees now (AWS-style strong vs bounded staleness).

## Recommendations

### Must Fix
- Specify the **metadata store choice and scaling model** (sharding/partitioning, txn isolation, hot partitions) and how `(bucket_id, seq)` is allocated without a single write bottleneck.
- Close the **commit invariant gap** between “metadata references manifest” and “shards are actually addressable under `chunk_id`” (remove re-key races or make them harmless).
- Clarify **consistency semantics** for `GET/HEAD` and especially `LIST` (strong vs bounded-stale) and ensure CRR preserves whatever you promise.
- Define **failure-domain placement** for EC (rack/AZ-aware), otherwise “11x9s within a region” is just an aspiration.
- Resolve **encryption vs content-addressing**: if per-tenant encryption is real, chunk IDs should be derived from ciphertext (or include tenant scope) to avoid cross-tenant dedupe/side-channels and key-rotation surprises.

### Should Consider
- Replace the bespoke Change Log with a **transactional outbox + CDC/Kafka**, and make replicator/lifecycle pure consumers (simpler ops, clearer replay story).
- Revisit **bucket-wide total order**: you likely only need deterministic order per key/prefix for correctness; global order may be the hidden scalability tax.
- Make **background backlogs first-class SLOs** with hard backpressure (ingest throttles when repair/CRR lag threatens durability/RPO).

### Nice to Have
- Operator runbooks for “repair lag exploding”, “CRR stuck”, “GC falling behind”, plus safe tooling to replay a bucket/prefix.
- Cost accounting tied to bytes+fanout (you already hint this)—make it part of the architecture contract, not an ops note.

## What’s Working Well
- The separation of concerns (metadata correctness vs immutable data plane) is clean and composable; it makes retries/repairs/replication *naturally idempotent*.
- Single-writer home region per bucket is an excellent trade to keep semantics S3-like without inventing a distributed database.
- Modeling lifecycle/CRR as metadata transitions is the right way to prevent “background job wrote state that never existed” bugs.
- The design calls out the real operational truth: repair/GC/replication backlogs are the durability system—good instinct to surface them early.