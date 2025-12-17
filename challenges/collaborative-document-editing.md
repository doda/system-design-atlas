## Elegance Check

### The Core Insight
Make the client authoritative for edit semantics (CRDT), and keep the backend “boring”: authenticate, fanout, and durably persist an append-only update stream with bounded replay via snapshots/compaction.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Clients (CRDT) | Only place that can guarantee sub-150ms local edits + offline-first merge correctness. |
| Auth & Permissions | Tight doc-scoped tokens on handshake is the cleanest way to keep the gateway stateless without security footguns. |
| Collab Gateway | WebSocket termination + rate limiting + fanout is its own scaling problem; keeping it stateless is the right instinct. |
| Doc Sync API | Single “durable edge” where idempotency, retention policy, and snapshot pointers live; avoids mixing durability concerns into the gateway. |
| Postgres (log+meta) | Boring correctness for metadata + unique constraints for idempotency; good default until the write rate forces a log system. |
| Object Storage (snapshots) | Cheapest way to store large immutable blobs; the right place for snapshots/exports. |
| Compactor Jobs | The mechanism that makes CRDT history bounded and keeps reconnect/cold-start predictable. |
| Realtime PubSub (Redis) | Low-latency broadcast primitive that’s operationally familiar (but see simplifications below). |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Redis PubSub for fanout | Sticky routing per `doc_id` + in-gateway in-memory fanout (Redis only for cross-node or not at all initially) | Simpler data plane, but you need consistent hashing + connection draining discipline; cross-node presence requires more thought. |
| “State-vector catch-up” while server is operation-agnostic | Either (A) accept “send all deltas since snapshot” or (B) let `Doc Sync API` keep per-doc CRDT state in-memory to compute true diffs | (A) simpler but higher bandwidth; (B) more complexity but matches the promise of state-vector efficiency. |
| Separate `Collab Gateway` and `Doc Sync API` hops for every update | Combine them (gateway persists directly) with an outbox/transactional publish | Fewer moving parts/latency, but harder to keep codebase clean; you must get “persist vs publish” ordering right. |
| Postgres update log partitions per doc | Start with coarse sharding (hash buckets) + append-only table + BRIN indexes | Less partition management complexity; might sacrifice some per-doc locality. |
| Custom compaction correctness | Treat compaction as “build new snapshot + validate + switch pointer” and keep old snapshots/deltas for a safety window | Uses more storage, but dramatically reduces risk of irreversible corruption. |
| Presence as “another channel” | Redis keys with TTL + periodic heartbeats (or gateway-only ephemeral presence) | Loses some real-time fidelity across gateway nodes unless you add cross-node gossip/Redis. |

## Stress Test

### Failure Scenarios
1. **Postgres is down for 5 minutes**
   - Design’s answer: partially addressed (mentions Postgres slow, not hard-down)
   - Recommendation: Strengthen — define a durability contract: do clients require an ACK from `Doc Sync API` to consider an edit “saved”? If DB is down, either (a) reject with clear “offline/unsaved” UX while still allowing local edits, or (b) accept into a bounded gateway buffer (risky) with explicit backpressure and loss semantics.

2. **Publish succeeds but persistence fails (or vice versa)**
   - Design’s answer: not addressed explicitly
   - Recommendation: Must fix — choose one:  
     - **Persist-then-publish** (strong consistency for “what others saw will reload”), or  
     - **Publish-then-persist** with explicit “ephemeral until committed” semantics and client reconciliation to avoid “ghost edits” after reload.  
     A transactional outbox pattern (or a per-doc sequencer shard) is the cleanest way to avoid split-brain between realtime and durability.

3. **Network partition: gateway ↔ Redis, but gateway ↔ clients is fine**
   - Design’s answer: addressed (fallback to persist-only + client polling)
   - Recommendation: Acceptable — add guardrails: polling jitter/backoff to avoid thundering herds, and a “doc-level slow mode” when pubsub is degraded.

4. **Compactor bug produces a bad snapshot (silent divergence)**
   - Design’s answer: not addressed
   - Recommendation: Must fix — compaction is the highest-risk component. Add: snapshot checksums, “apply snapshot + tail updates” verification in the job, keep previous snapshot pointer for quick rollback, and delay deletion of old deltas (safety window) so you can recover.

5. **Hot doc spike (200 editors, paste storms) causes backpressure**
   - Design’s answer: partially addressed (rate limits, snapshot frequency)
   - Recommendation: Strengthen — add explicit per-doc backpressure behavior: bounded outbound queues per connection, drop/merge presence updates first, and a clear policy for when to disconnect vs degrade (and how clients resync cleanly).

## Recommendations

### Must Fix
- Reconcile the tension between “server doesn’t understand ops” and “state-vector selective catch-up”: either accept replay-since-snapshot, or explicitly run CRDT state in `Doc Sync API` (even if only on compactor/shards).
- Define ordering/atomicity between persistence and broadcast (avoid ghost edits) and document the client’s “saved vs seen” semantics.
- Make compaction safe-by-design: validate snapshots, keep rollback pointers, and don’t delete deltas immediately.
- Harden abuse/DoS edges: cap update size, protect against compression bombs, rate-limit per doc/user, and ensure `author_device_id` is server-minted/bound (not client-chosen).

### Should Consider
- Collapse components early (gateway + sync) to reduce operational surface area, then split only when metrics demand it.
- Consider Postgres `LISTEN/NOTIFY` (or a single-region “good enough” pubsub) for earlier stages to remove Redis until scale forces it.
- Add an explicit “stale client” UX path: forced snapshot reload with clear messaging and automatic recovery.

### Nice to Have
- “3am tools”: per-doc timeline inspector (snapshot ids, update counts, last compaction), one-click disable compactor, and replay/verify tooling.
- Canary compaction + gradual rollout of CRDT library upgrades (client and server) to avoid format/version mismatch incidents.

## What's Working Well
- The separation of durable edits vs ephemeral presence is exactly the right reliability boundary.
- Idempotent writes with `(doc_id, author_device_id, monotonic_seq)` is a solid foundation for retries and flaky networks.
- Snapshot + append-only log framing is operationally legible and gives you clean knobs (snapshot interval, retention).
- You’re explicit about the real hard part (bounded history/compaction) and treat it as a first-class design axis, not an afterthought.