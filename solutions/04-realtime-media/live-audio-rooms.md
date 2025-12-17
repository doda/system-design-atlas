---
generation_time_seconds: 918
title: "Live Audio Rooms"
category: "Real-Time & Media"
difficulty: "Hard"
tags: ["webrtc", "sfu", "realtime", "moderation", "fanout", "media"]
---

## Overview

Live Audio Rooms is a real-time audio conversation product (Clubhouse/Twitter Spaces style): a small set of speakers talks to a large set of listeners with low latency, while moderators can instantly control who is allowed to speak.

The design is two pieces:
- a **control plane** that decides room truth (roles, queue, moderation)
- a **media plane** (SFU) that forwards audio and enforces that truth at line rate

The live path is SFU forwarding (no server-side mixing): speakers publish to the SFU, listeners receive a few streams and mix locally. Moderation is enforced at the SFU so “mute/kick” changes what listeners hear immediately.

## What Makes This Hard

The two failure patterns:
1. **Server-side mixing (MCU) by default:** turns every room into CPU scaling + quality/latency problems.
2. **Soft moderation:** “mute/kick” in the backend/UI only; the SFU still forwards packets for seconds.

The hard part is making “who may publish audio” consistent and enforced where packets flow.

## Requirements

### Functional Requirements

- **Roles & permissions:** listener, speaker, moderator, admin; moderators can promote/demote speakers.
- **Hard mute / kick:** moderators must be able to stop a user’s audio being delivered *immediately* (target < 300ms).
- **Hand-raise & speaker queue:** fairness and anti-spam controls (rate limits, cooldowns).
- **Audio mixing semantics:** listeners hear a single “room experience” even though it’s composed of multiple speaker streams (ducking / active-speaker emphasis).
- **Observability for moderation:** who spoke when, speaking time, join/leave, moderation actions (for trust & safety review).
- **Resilience:** transient network issues should not collapse the room; reconnection should be fast and safe.

### Scale Targets

Assume a successful consumer product:

- **Concurrency:** 200k concurrent listeners globally at peak; 20k concurrent rooms.
- **Speakers per room:** typical 2–6, hard cap 12 (beyond this the UX degrades anyway).
- **One “celebrity room”:** 100k concurrent listeners in a single room.
- **Latency target:** p95 mouth-to-ear < 300ms for listeners in the same region; < 500ms cross-region.
- **Audio:** Opus 16–24 kbps (wideband), 20ms frames.

These numbers matter because SFU scaling is dominated by **egress bandwidth** (fan-out), while moderation correctness is dominated by **state consistency and enforcement location**.

## Key Design Decisions

- **Choose:** WebRTC + SFU forwarding + client-side mixing for the live path  
  **Reject:** always-on MCU mixing  
  **Why:** rooms have few speakers and many listeners; forwarding N speaker streams is cheaper and more failure-tolerant than mixing, and lets each client adapt jitter buffering and output.

- **Choose:** a single-writer room state machine that issues **per-speaker publish leases** enforced at the SFU  
  **Reject:** room-wide epoch bumps (blast radius) or trusting clients  
  **Why:** one moderation action should affect one publisher, and enforcement must happen at the SFU.

- **Choose:** SFU relay trees for “celebrity rooms”  
  **Reject:** a single SFU handling all egress for a mega room  
  **Why:** egress bandwidth, not CPU, is the scaling cliff; relay trees spread egress across the cluster.

## Architecture

```mermaid
flowchart LR
  C[Clients] <--> R[Room Service]
  C --> T[TURN/STUN]
  C <--> S[SFU Cluster]

  R --> P[(Postgres)]
  R --> S
  R --> O[Metrics/Logs]
  S --> O

### Components

- **Clients (iOS/Android/Web):** WebRTC stack + local mixing; without local mixing, you’re forced into server-side mixing or a more complex media pipeline.
- **Room Service (control plane):** the authoritative room state machine (roles, queue, moderation) and signaling; without it, moderation outcomes are inconsistent under concurrency.
- **Postgres:** durable room metadata + append-only moderation/audit log + idempotency keys; without it, trust & safety review and “what happened?” questions are guesswork.
- **TURN/STUN:** NAT traversal; without it, a meaningful slice of mobile networks simply won’t connect reliably.
- **SFU Cluster (media plane):** bandwidth-efficient fan-out and the only place that can guarantee “mute/kick” changes what listeners receive.
- **Metrics/Logs:** required to debug real-time issues and to verify moderation actions were enforced (or not).

## Deep Dive: Moderation That Actually Works (Enforced at the SFU)

The hardest part is guaranteeing that a moderation action changes what the audience hears quickly and reliably. The system needs to answer: *Who is allowed to publish audio right now?* and ensure the answer is applied at the packet-forwarding point.

**1) Make room state a single-writer state machine.**  
Each room is handled by one Room Service worker at a time. It assigns a monotonic `seq` to every accepted command (grant/mute/kick/promote), and broadcasts the updated room state to connected clients.

This `seq` is for client state sync and auditing; it is not used to gate publishing.

**2) Bind media publishing to an authorization lease.**  
When a user becomes a speaker, the Room Service issues a short-lived “publish lease”:
- contains `room_id`, `user_id`, allowed MIDs/SSRCs, and `(lease_id, lease_version)`
- is pushed to the SFU over a control channel and also given to the client
- TTL is 20s and refreshed every 10s

The SFU only forwards packets that match an active lease for that publisher. Mute/kick updates only that speaker’s lease state (no room-wide invalidation).

**3) Make “hard mute” a media-plane action, not a UI action.**  
Clients may still send RTP after being muted (bugs, malicious users, jittery reconnections). The SFU enforcement makes the listener experience correct even when publishers are wrong. For extra safety, the SFU can also terminate the publisher’s peer connection on kick.

**4) Use audio-level signals for UX without trusting clients.**  
The SFU computes per-stream audio levels (RFC6464-style) and sends them to clients for active-speaker highlighting and automatic ducking. This prevents “fake speaking” clients from manipulating the UI.

**5) Define SFU-control partition behavior.**  
If the SFU can’t receive updates from the Room Service:
- **new publishes fail closed immediately** (no fresh lease, no forwarding)
- **existing publishes are bounded by lease TTL** (lease expires → forwarding stops)
- the SFU can **pull** the latest allowlist on demand when it detects stale/expired leases

**6) Handle reconnects safely with leases and idempotency.**  
On reconnect, a speaker must re-signal and obtain a fresh lease. The Room Service uses idempotency keys for moderation commands so retries don’t duplicate transitions, and writes an ordered audit log to Postgres.

This is the elegant boundary: the control plane decides truth; the media plane enforces truth at line rate.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Low latency and scalable fan-out | “One mixed stream” simplicity |
| Strong, fast moderation guarantees | More SFU-control integration |
| Simple room-state consistency (single-writer) | Cross-region active/active room writes |
| Fewer moving parts (no event bus) | Less built-in replay/async consumers early |
| Per-speaker revocation | Slightly more state at the SFU |

## Failure Modes

- **Postgres is down for 5 minutes**  
  - Happens: room creation/audit writes fail; trust & safety visibility degrades.  
  - Detect: DB health + write error rate.  
  - Recover: keep live rooms running from in-memory room state; buffer audit events in memory (bounded) and flush when Postgres returns; when the buffer is full, stop accepting speaker changes and moderation commands.

- **Room Service ↔ SFU control channel is partitioned (media still flows)**  
  - Happens: moderation updates can’t be pushed to the SFU.  
  - Detect: missed control heartbeats/acks per room.  
  - Recover: SFU fails closed for new publishes; existing speakers stop at lease expiry; when the channel recovers, refresh allowlists immediately.

- **SFU overload (CPU or egress saturation)**  
  - Happens: audio stutters, increased packet loss, join failures.  
  - Detect: per-SFU egress, packet loss, jitter, ICE failures, queue depth.  
  - Recover: admission control (cap speakers), move room to a larger SFU pool, enable SFU relay trees for mega rooms, shed non-essential features first.

- **Bad SFU config deploy (codec/ICE/auth bug)**  
  - Happens: join failures or broken moderation checks across many rooms.  
  - Detect: canary pool error-rate deltas, join-success and mute/kick enforcement SLOs.  
  - Recover: canary rollout, instant rollback to last-known-good config, keep a “safe mode” config (no optional features) for incident response.

- **Room Service instance crash while a room is live**  
  - Happens: role changes pause; media may continue briefly with last-known leases.  
  - Detect: instance health, WS disconnect spikes, stalled `seq` for the room.  
  - Recover: clients reconnect; Room Service rebuilds room state from Postgres and resumes issuing leases; if it can’t rebuild, it locks the room and lets existing leases expire.

- **Regional outage / backbone partition**  
  - Happens: users in the region disconnect; celebrity rooms fragment.  
  - Detect: regional ICE/connect failure spikes, SFU pool unreachable.  
  - Recover: pin each room’s control + SFU to a primary region; on outage, reconnect users to a new region and restart the room cleanly with a clear UX message; keep the Postgres audit log as the source of truth.

## What We Removed

- **Event bus (Kafka/Pulsar):** room events live in Postgres (append-only moderation/audit log); stream/ETL later if needed.
- **API gateway as a separate component:** auth and rate limits live in the Room Service for the early system.
- **Room-wide epoch bumps on mute/kick:** replaced with per-speaker leases so one action affects one publisher.
- **Custom shard coordination:** room state lives in one Room Service worker; crashes recover by reconnect + rebuild from Postgres.
