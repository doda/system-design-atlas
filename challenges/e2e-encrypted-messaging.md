## Elegance Check

### The Core Insight
Treating “multi-device” as *multiple cryptographic endpoints* (and making “sync” fall out of normal message fanout) is the cleanest way to keep forward secrecy + post-compromise security without inventing a parallel trusted sync plane.

### Components That Earn Their Place
| Component | Why It's Necessary |
|-----------|-------------------|
| Client crypto (X3DH + Double Ratchet) | Core security properties (FS/PCS) live only on devices; server stays out of confidentiality. |
| Key directory | Asynchronous session setup requires a discoverable, authenticated prekey/device directory. |
| Message relay (per-device mailbox) | Reliability primitives (durable queue, retries, backpressure) without becoming a “plaintext brain.” |
| Blob store | Attachments are naturally object storage; ciphertext-at-rest aligns with S3-like primitives. |
| Push gateway | Wakes offline devices; keeps mailbox fetch pull-based (simpler correctness). |
| Key transparency log | The only credible way to make “server swapped keys” *detectable* at scale without constant out-of-band checks. |

### Simplification Opportunities
| Current | Simpler Alternative | Trade-off |
|---------|---------------------|-----------|
| Bespoke “key directory + separate transparency log” | Use an existing transparency log implementation (e.g., Trillian-style) and treat the directory as a signed-view service over it | Faster to get right; still adds client verification complexity. |
| Relay checks `device_epoch` by consulting directory state | Issue a short-lived, directory-signed “delivery authorization token” (contains epoch + expiry) that the relay can verify offline | Less coupling/latency; introduces token minting/rotation and clock-skew considerations. |
| “DeviceCert = Sign_IK(...)” with a per-user IK used for device enrollment | Split keys: offline/root “Account Root” signs *device admin keys*; day-to-day devices only hold delegated keys (or hardware-backed non-exportable root) | More ceremony, but fixes the “compromised device leaks IK” inconsistency. |
| “Add device requires an existing device” only | Add a break-glass recovery path: user-held recovery key / printed QR / secure backup that can authorize a new device and rotates identity | Weakens “no server help” purity, but avoids account lockout when all devices are lost. |
| OPK inventory enforcement via policy/blocks | Prefer soft-fail + backpressure: rate-limit unauthenticated prekey fetch, per-sender quotas, and “message request” gating to prevent OPK burn DoS | Slightly more product logic; much better resilience under abuse. |

## Stress Test

### Failure Scenarios

1. **Key directory down for 5 minutes**
   - Design's answer: not addressed (directory is operationally critical; sessions are “long-lived” but device epoch enforcement can force refetch)
   - Recommendation: Strengthen (explicit client behavior: send using existing sessions if possible; if epoch mismatch, queue locally with clear UX; define SLO + multi-region read strategy)

2. **Removed device still fetches queued messages**
   - Design's answer: relay rejects sends with stale epoch (prevents *new* delivery) but doesn’t explicitly address *fetch-time revocation* or already-queued ciphertext
   - Recommendation: Must fix (revocation must gate both `send` and `fetch`: short-lived device auth tokens, immediate disable, and mailbox access checks; optionally delete/purge mailboxes on removal)

3. **Compromised existing device adds a spyware device**
   - Design's answer: “server can’t forge without existing device/IK”
   - Recommendation: Strengthen (be explicit: if an existing device is compromised, it can approve new devices—this is unavoidable unless you require multi-party approval, hardware-bound keys, or an out-of-band recovery factor; document this trade-off honestly)

4. **Abuse/DoS: attacker burns OPKs or floods prekey messages**
   - Design's answer: monitor OPK inventory; block devices that don’t replenish
   - Recommendation: Strengthen (inventory monitoring is necessary but insufficient—add rate limits on prekey bundle fetch, per-account quotas, spam gating/message requests, and avoid “consume OPK on fetch” semantics unless tied to authenticated send)

5. **Bad config bumps epochs or serves inconsistent device lists**
   - Design's answer: transparency log + epoch mismatch rejection
   - Recommendation: Acceptable if clarified (spell out rollback protection: signed monotonic versions, client pinning rules, and what happens if the log/directory disagree; add a safe deploy story: canary + read-only mode for directory writes)

## Recommendations

### Must Fix
- Resolve the key-hierarchy inconsistency: if devices can sign with `IK`, then compromising that device compromises `IK`; either make `IK` hardware-backed/non-exportable or introduce a root/delegation model (root signs device-admin keys; devices sign device certs).
- Define revocation semantics precisely: device removal must immediately prevent *mailbox fetch* (not just new sends), including token invalidation strategy.
- Add an explicit “lost all devices” recovery story (user-held recovery key + identity rotation + clear UX for contacts).

### Should Consider
- Decouple relay from directory reads using directory-signed delivery tokens (epoch + expiry), reducing hot-path dependencies.
- Make abuse controls first-class: prekey fetch rate limits, OPK burn resistance, and spam gating for unsolicited first-contact messages.
- Clarify group/device lifecycle interactions: how new devices join groups (sender-key distribution), and how removals trigger key rotation without causing long offline members to brick.

### Nice to Have
- Formalize invariants and delivery semantics (at-least-once vs exactly-once, dedupe IDs, replay handling) so the “boring relay” stays boring.
- Incremental rollout path for key transparency (start with pinning + safety numbers; add log + witnesses later) to match a small-team complexity budget.

## What's Working Well
- “Sync by fanout” is conceptually uniform and keeps sensitive state on clients while using the server for reliability where it’s strongest.
- The device epoch idea is a pragmatic fix for the most common real-world failure (stale device list) and aligns with operational realities.
- The design is honest about the key product/security trade-off (no automatic history on new devices) and points to the right solution (explicit encrypted backups) rather than smuggling shared keys back in.