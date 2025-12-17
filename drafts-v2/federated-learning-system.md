```markdown
---
title: "Federated Learning System"
category: "AI/ML Infrastructure"
difficulty: "Hard"
tags: ["federated-learning", "secure-aggregation", "privacy", "differential-privacy", "edge"]
---

## Overview

This system coordinates federated learning rounds across millions of edge devices and produces a global model without ever seeing any individual device’s model update. The core idea is to treat “privacy-preserving FL” as a *reliable, large-scale secure aggregation service with deadlines*, not as an ML pipeline problem. If you can securely sum vectors from unreliable clients at high fan-in, everything else is boring plumbing.

The elegant move is to pick one privacy primitive that scales operationally: **Secure Aggregation (SecAgg)** for confidentiality of individual updates, plus **server-side differential privacy (DP)** on the *aggregate* to reduce leakage from the final model. We avoid complex custom cryptography: use a well-known dropout-resilient SecAgg protocol and standard storage/queues to survive partial failures and massive client churn.

## What Makes This Hard

Naive implementations die on two traps:

1. **Dropout + fan-in breaks privacy or availability.** With millions of devices, most cohorts have stragglers, disconnects, and retries. If the protocol can’t handle dropout cleanly, you either (a) wait forever, (b) reveal individual updates to debug, or (c) silently bias training by over-representing “always-online” devices.

2. **You can’t “inspect” updates without breaking the promise.** Typical ML safety tools (per-client anomaly detection, per-client clipping enforcement, blacklisting) assume the server can see individual gradients. In privacy-preserving FL, the server mostly sees only an aggregate, so you must design robustness around what you *can* observe.

## Requirements

### Functional Requirements
- Coordinate FL rounds: cohort selection, protocol handshakes, deadlines, retries, and completion.
- Aggregate updates without exposing any individual update to the server or other clients (SecAgg).
- Limit information leakage from the released model (aggregate DP with clipping + noise).
- Support model/version rollout and rollback with strict reproducibility of “what trained what.”
- Provide auditable privacy accounting (epsilon/delta budget per model lineage).

### Scale Targets
- **Total devices enrolled:** 50M (order of magnitude: “millions”).
- **Daily active participants:** 2M (realistic participation, charging/Wi‑Fi constraints).
- **Per-round cohort size:** 20k invited, target **10k completed** (assume ~50% dropout).
- **Rounds per day:** 200 (continuous training; smaller cohorts reduce tail latency).
- **Update size:** 5–20 MB compressed (depends on model; drives bandwidth + storage).
- **Ingest peak:** 10k uploads / 10 min ≈ 17 uploads/sec sustained, but bursty; design for **10× spikes**.

These numbers matter because they force: (a) strict deadline-based round management, (b) storage-backed protocol state, and (c) aggregation that is parallelizable and restartable.

## Key Design Decisions

- **Chose: Dropout-resilient Secure Aggregation (Bonawitz-style) with cohorts**
  - **Rejected:** “Just upload encrypted updates to a trusted server,” or TEEs-only designs.
  - **Why:** It keeps the server honest-by-design (it literally can’t see individual updates) while tolerating real-world dropout without bespoke infra.

- **Chose: Aggregate DP (clip then noise) at the server on the summed update**
  - **Rejected:** “Privacy via SecAgg alone.”
  - **Why:** SecAgg hides individual updates from the server, but the *trained model* can still leak information. DP on aggregates is the simplest defensible mitigation with a clear accounting story.

- **Chose: Make the coordinator stateless; persist round state in Redis/Postgres; blobs in object storage**
  - **Rejected:** Stateful coordinator instances holding protocol state in memory.
  - **Why:** Rounds last minutes; coordinator restarts and deploys must not abort cohorts or (worse) force fallbacks that violate privacy.

## Architecture

```mermaid
flowchart LR
  D[Edge Devices] --> G[API Gateway]
  G --> C[Round Coordinator]
  C --> R[Round State (Redis)]
  C --> O[Object Storage]
  C --> W[Aggregation Workers]
  W --> M[Model Registry]
  C --> X[Observability]
  W --> X[Observability]
```

### Components

- **API Gateway**
  - Terminates TLS, enforces quotas, and gives you a single choke point for abuse control (per-device rate limits, replay protection).

- **Round Coordinator**
  - Orchestrates SecAgg phases (setup/upload/unmask), assigns devices to cohorts, enforces deadlines, and emits “round ready” work items.
  - Earns its place by being the only component that understands the protocol state machine.

- **Round State (Redis)**
  - Fast, TTL-heavy state: cohort membership, phase transitions, acks, timeouts, idempotency keys.
  - Redis is “boring good” for ephemeral coordination; Postgres backs durable metadata.

- **Object Storage**
  - Stores large per-round artifacts (encrypted update shares, masked updates, worker intermediate shards) with lifecycle rules and immutability for audit.

- **Aggregation Workers**
  - Parallelize the heavy compute: verify protocol completeness, sum masked vectors, apply unmasking contributions, then apply DP (clip/noise) and produce the final model delta.

- **Model Registry**
  - Stores model versions, training configs, privacy budget consumption, and provenance (round IDs, cohort stats, code hash).

- **Observability**
  - Dropout rates, phase latencies, per-round completion distribution, DP budget burn, and anomaly signals on aggregates (norms, loss deltas).

## Deep Dive: Secure Aggregation With Massive Dropout

The hardest part is **getting a correct sum without seeing any individual update, despite half the cohort disappearing**.

I use a standard dropout-resilient SecAgg flow with three phases and explicit deadlines:

1. **Setup phase (pairwise mask establishment)**
   - Each device generates ephemeral keys and exchanges public material via the coordinator.
   - Devices derive pairwise masks with peers and commit to what they’ll later reveal if needed (e.g., secret shares of seeds).
   - Coordinator persists membership + public materials; it never sees plaintext masks or updates.

2. **Upload phase (masked updates)**
   - Each device uploads a *masked* model update vector: `u_i + Σ masks(i,j)`.
   - Coordinator stores blobs and counts completions. Devices can retry idempotently using round+device nonce.

3. **Unmask phase (dropout resolution)**
   - The trick: if everyone finished, pairwise masks cancel in the sum. But with dropout, masks don’t cancel automatically.
   - Devices that completed upload now send *unmasking material* that lets workers remove masks for the devices that dropped.
   - Workers only ever recover enough to compute the cohort sum; they never reconstruct any `u_i` because (a) masks from online devices still cancel, and (b) seeds are only revealed for dropped participants.

Operationally, the design hinges on two non-obvious choices:
- **Deadline-based cohort closure:** You optimize for throughput and predictable tail latency, not “maximize participants.” A round that finishes with 10k updates every 10 minutes beats a round that waits 45 minutes for 12k.
- **Restartable aggregation:** every protocol message is persisted; workers can recompute the sum deterministically from stored artifacts. This is how you avoid “temporary debug mode” that leaks updates.

Finally, once the secure sum is computed, apply **DP on the aggregate**:
- Require devices to locally clip updates to norm `C` (enforced via attested client code).
- Workers optionally re-clip the *aggregate* defensively, then add calibrated Gaussian noise based on cohort size and budget.
- Record privacy accounting in the registry per model lineage.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Strong privacy guarantees (server can’t see individual updates) | Per-client debugging and rich per-client safety checks |
| Predictable round completion with high dropout | Slightly lower statistical efficiency vs “wait for everyone” |
| Simple, restartable ops (storage-backed state) | Higher storage and bandwidth overhead from protocol artifacts |

## Failure Modes

- **High dropout spike (e.g., OS update, regional outage)**
  - **What happens:** rounds fail to reach completion threshold; training stalls.
  - **Detect:** completion rate and phase timeout metrics; cohort completion histogram shifts.
  - **Recover:** reduce cohort size, widen invite pool, relax deadlines temporarily, and bias selection toward “historically reliable” devices (without changing privacy semantics).

- **Coordinator crash or deploy mid-round**
  - **What happens:** without persistence you’d lose protocol state and force unsafe fallbacks.
  - **Detect:** missing phase transitions, rising retry counts, stuck rounds.
  - **Recover:** coordinator is stateless; reload from Redis/Postgres; idempotent message handling resumes.

- **Model poisoning attempt**
  - **What happens:** attacker tries to skew the aggregate, but server can’t inspect per-client updates.
  - **Detect:** aggregate-level signals: abnormal update norm, unexpected loss change on holdout evaluation, distributional drift of aggregate deltas.
  - **Recover:** quarantine the produced model version, roll back, tighten cohort admission (attestation, reputation), reduce per-round influence via stricter clipping and increased noise, and require more rounds before promotion.

## What I'd Do Differently At...

- **10x scale:**
  - Shard by model+region more aggressively; run multiple coordinators per shard; move more state to Redis Cluster and use object storage partitioning to keep worker reads sequential.

- **100x scale:**
  - Re-architect aggregation into a hierarchical scheme (edge → regional → global) to cut WAN bandwidth, and invest in stronger robustness primitives (e.g., secure sketching / robust aggregation under encryption) because poisoning becomes the dominant risk.

## Operational Notes

- Watch **dropout by protocol phase**; spikes in setup vs upload indicate different problems (key exchange vs bandwidth).
- Treat **round deadlines** as a primary tuning knob; most outages manifest as tail latency blowups first.
- Enforce **strict versioning**: client code hash, model version, DP parameters, and selection policy must be part of round identity.
- Keep an explicit **privacy budget ledger** per model; “we ran more rounds” is not a free action once DP is in play.
```