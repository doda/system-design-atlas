---
generation_time_seconds: 371
title: "Smart Home Hub"
category: "IoT & Edge"
difficulty: "Hard"
tags: ["iot", "edge", "mqtt", "nat-traversal", "low-latency", "reliability"]
---

## Overview

This system routes user commands (e.g., “lock door”, “set thermostat”) to devices that are typically behind NATs and restrictive firewalls with low perceived latency.

Devices never accept inbound connections. Each device maintains a long-lived, authenticated outbound MQTT session to the cloud. Commands are published to the device’s topic; the broker delivers them over the device’s current session. Reliability comes from durable intent (Postgres) plus at-least-once delivery (MQTT QoS 1) plus device idempotency.

## What Makes This Hard

The hard part is correctness under churn: devices disconnect, reconnect, and sometimes reconnect twice. Delivery is at-least-once, so duplicates are normal. If you can’t make commands idempotent and you can’t be honest about offline behavior, you create “it said locked but didn’t” failures.

## Requirements

### Functional Requirements
- Route a command to the correct device even when it is behind NAT/firewall.
- Provide bounded-latency command push when device is online; provide clear semantics when offline (queued vs rejected).
- Ensure idempotent execution: the same command may be delivered more than once.
- Provide an auditable command trail: who issued what, when, and what the device acknowledged.
- Support device connectivity over restrictive networks: MQTT over TLS (8883) and MQTT over WebSockets (443).

### Scale Targets
- Online devices: 5M concurrent connections.
- Command rate: 50k commands/sec peak (bursty).
- Latency (online): p50 < 150ms, p95 < 500ms end-to-end.
- Offline tolerance: devices may be offline for hours; reconnect storms must not melt the system.

## Key Design Decisions

- MQTT persistent sessions + QoS 1 for device-initiated connectivity.
- The MQTT broker is the session owner and routing authority (publish to a device topic goes to the device’s current connection).
- Accept/queued/rejected semantics are driven by durability + online-ness:
  - `accepted`: command is persisted in Postgres.
  - `queued`: command is persisted and eligible for delivery on reconnect (bounded by TTL/backlog policy).
  - `rejected`: command is not persisted (or is unsafe while offline).
- Device-side idempotency with `command_id` is mandatory; duplicates are expected.
- Reliable publish uses a transactional outbox in Postgres; workers batch with `SKIP LOCKED` and are woken via `LISTEN/NOTIFY`.

## Architecture

```mermaid
flowchart LR
  A["Apps"] --> B["Command API"]
  B --> C["Postgres"]
  C --> D["Outbox Worker"]
  D --> E["MQTT Broker (Regional)"]
  E --> F["Devices"]
  F --> E
```

### Components

- `Command API`: Authenticates the user, checks authorization (user can control device), assigns `command_id`, persists intent, and returns `accepted/queued/rejected`. This is the single place where user-facing semantics stay consistent.
- `Postgres`: Source of truth for accounts/devices/ACLs plus the command log and outbox. If Postgres is unavailable, the system fails honestly and does not “accept” commands.
- `Outbox Worker`: Publishes persisted commands to MQTT reliably with bounded retries, backoff, and batching. It also expires commands (`expires_at`) and stops retrying rather than retrying forever.
- `MQTT Broker (Regional)`: Maintains long-lived device sessions, handles reconnect/takeover for a device identity (single `client_id` per `device_id`), queues QoS1 messages for persistent sessions within configured bounds, and exposes “connected/not connected” for offline policy.
- `Devices`: Subscribe to their command topic, dedupe by `command_id`, execute, and publish acknowledgements (received/accepted; optionally executed/result).

## Deep Dive: Connection-Aware Command Routing (The Hardest Part)

**1) Session ownership and split-brain**  
Each device uses a stable MQTT `client_id = device_id`. The broker is configured to allow only one active connection per `client_id`; a new connection takes over and the old one is dropped. Publishing to the device’s topic always targets the current owner session, so stale routing state is not a separate system.

**2) Durability and publish without lying**  
The `Command API` persists `commands` + `outbox` in one Postgres transaction. Only after commit does it return `accepted` (or `queued` if the command is allowed to wait for reconnect). Publishing is asynchronous; delivery is proven by device ACK, not by API response.

**3) Offline policy is explicit and bounded**  
Every command has `expires_at`. Each device class has a max backlog and a default offline stance:
- Safe commands: may be `queued` until `expires_at` (bounded by per-device backlog).
- Unsafe commands (e.g., unlock/open/disable alarm): `rejected` if the device is not connected right now.

**4) At-least-once + idempotency**  
Every command includes `command_id`, `issued_at`, `expires_at`, and optional `expected_state_version`. Devices store a small recent set of executed `command_id`s and re-ACK duplicates without re-executing.

## Trade-offs

| Optimized For | Sacrificed |
|--------------|------------|
| Simple, correct routing via broker-owned sessions | Exactly-once delivery semantics |
| Honest accept semantics (no accept without persistence) | Availability of “accept” during Postgres outages |
| Fewer moving parts (no separate presence directory) | Reliance on broker capabilities/ops maturity |
| Safe offline behavior via TTL/backlog/policy | Some commands must be rejected when offline |

## Failure Modes

- **Postgres down for 5 minutes**
  - Behavior: `Command API` returns `503` and does not accept commands.
  - Rationale: no persistence means no audit trail and no reliable publish; the system stays honest.

- **Regional broker outage**
  - Behavior: devices disconnect; publishes fail; outbox retries with backoff until expiry.
  - Recovery: devices reconnect when broker returns; queued commands still within TTL deliver; expired commands are marked failed/expired.

- **Reconnect storm**
  - Behavior: connection rate spikes.
  - Recovery: broker/gateway layer enforces connection budgets and handshake caps; devices follow a backoff contract; outbox publishing remains bounded and does not overwhelm Postgres.

- **Duplicate/out-of-order delivery**
  - Behavior: duplicates happen under QoS1 and reconnect.
  - Recovery: device dedupe by `command_id`; optional `expected_state_version` rejects stale commands explicitly.

- **One component is slow (publish or DB under pressure)**
  - Behavior: lag increases.
  - Recovery: bounded outbox concurrency, bounded retries, and command expiry prevent infinite retry; per-tenant and per-device rate limits prevent one hot tenant/device from consuming capacity.

## What We Removed

- `API Gateway`: folded into `Command API` (auth, rate limits, request normalization live in one service boundary).
- `Device Gateway`: broker terminates device auth and owns session lifecycle for a `device_id`.
- `Presence (Redis)`: routing is broker-owned; “connected now?” is derived from the broker rather than a separate directory.
- Custom offline/retained mechanisms: offline behavior is MQTT persistent session queueing plus explicit TTL/backlog and per-command policy.

## Operational Notes

- Keepalive tuning is an SLO lever (battery vs NAT stability vs broker CPU).
- Configure broker limits explicitly: max inflight, max queued per client, max message TTL, and connection takeover behavior per `client_id`.
- Track three signals: outbox lag, broker publish/ACK latency, and connection churn; those predict user-visible failures early.
