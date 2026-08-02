# AirGrid

**Offline-first peer-to-peer mesh chat for Android.**

AirGrid lets nearby Android devices exchange messages without internet, mobile
data, a router, or a centralized server. It runs locally over Bluetooth and
Wi-Fi Direct through Google Nearby Connections.

The app is Android-only. iOS is not supported because the current transport
depends on the Android Nearby Connections stack.

## Current Status

AirGrid currently supports:

- public nearby mesh chat
- direct private chat
- opportunistic encrypted private messaging with X25519 key agreement
- image, voice-note, and file attachments on private threads
- push-to-talk walkie-talkie with invite/accept session control, plus a
  public walkie mode
- store-and-forward for encrypted private packets
- SQLite message persistence
- known-contact persistence
- secure local key storage with migration from legacy preferences
- strict input validation for remote packets
- per-peer rate limiting for flood resistance
- foreground service support for active mesh sessions
- location sharing between connected peers

## Implementation Map

The current codebase matches the documented architecture:

- **Transport:** `NearbyConnectionsTransport` is implemented in
  `lib/data/transport/nearby_connections_transport.dart` and is the only layer
  that imports `nearby_connections`.
- **Routing:** `AirGridMeshService` in `lib/domain/services/mesh_service.dart`
  owns packet routing, validation, deduplication, encryption decisions, relay,
  rate limiting, fragmentation, and spool behavior.
- **Identity and storage:** `LocalIdentityStore` in
  `lib/data/storage/local_identity_store.dart` manages stable node identity and
  X25519 key material.
- **Persistence:** `SqliteMessageRepository` in
  `lib/data/storage/sqlite_message_repository.dart` stores chat history and
  manages schema migrations.
- **Crypto:** `CryptoService` in `lib/core/crypto_service.dart` uses X25519 key
  agreement with ChaCha20-Poly1305 for encrypted private message content.
- **Store-and-forward:** Bounded private-message spooling is implemented in
  `AirGridMeshService` and configured through `lib/core/constants.dart`.
- **Safety controls:** Rate limiting and validation live in
  `lib/core/rate_limiter.dart` and `lib/core/validation.dart`.
- **Android integration:** Foreground service support and required Android
  Nearby/Bluetooth/location permissions are implemented under
  `lib/core/foreground_service_bridge.dart` and
  `android/app/src/main/AndroidManifest.xml`.
- **Testing:** Unit, integration, and widget tests are present under `test/`.

## Requirements

| Item | Minimum |
| ---- | ------- |
| Android SDK | API 21 (Android 5.0) |
| Google Play Services | Required |
| Flutter | Stable channel with the repo's configured Dart SDK |
| Devices | Physical Android devices for real mesh testing |

Emulators are useful for UI and unit tests, but real Bluetooth and Wi-Fi Direct
mesh behavior should be tested on physical devices.

## Privacy Policy

AirGrid's published privacy policy is available at
https://airgridmessenger.netlify.app.

## Setup

```bash
flutter pub get
flutter test
flutter analyze
flutter run
```

To run on Android, connect a physical device with Google Play Services
available.

### Build environment

Development is on **Windows x86-64**, which builds Android natively with no
workarounds. CI runs on `ubuntu-latest`, also x86-64 — that is fine and should
stay as it is.

The constraint worth knowing is architectural, not about the OS: Google ships
AAPT2, CMake and the NDK toolchain as **x86-64 binaries only**. On an
**aarch64** host they cannot execute, and the usual escape is a Gradle init
script pinning `abiFilters` to a single ABI so the link step stops crashing.
That produces a bundle missing `armeabi-v7a`, which uploads happily and
silently drops 32-bit devices.

`flutter test` and `flutter analyze` are pure Dart and pass on any
architecture, so nothing warns you until a real build. Two defences:

- Nothing in this repo sets `abiFilters`. Keep it that way; the defaults are
  correct.
- `build_release_aab.ps1` inspects the finished bundle and refuses to pass a
  build that is missing `arm64-v8a` or `armeabi-v7a` (see below).

If you ever build on a non-x86-64 host, treat any init script under
`~/.gradle/init.d/` as a release hazard and do not let it near a Play upload.

## Play Console Release Flow

Use the release helper script so every AAB build also bumps app version and
build number in `pubspec.yaml`.

Auto-increment patch + build (recommended):

```powershell
./build_release_aab.ps1
```

Set explicit version name and build number:

```powershell
./build_release_aab.ps1 -VersionName 1.0.3 -BuildNumber 4
```

After running, upload:

```text
build/app/outputs/bundle/release/app-release.aab
```

The Settings screen reads app version from platform package info, so this
workflow keeps the in-app version label aligned with the Play Console artifact.

The script ends with an **ABI check**: it opens the bundle and lists the ABIs
actually inside it, then throws if `arm64-v8a` or `armeabi-v7a` is missing. A
passing run prints:

```text
AAB ABIs: arm64-v8a, armeabi-v7a, x86_64
ABI check passed: 32-bit and 64-bit ARM both present.
```

If it throws, **do not upload the bundle** — a missing `armeabi-v7a` means
Play will stop serving 32-bit devices, and that is not visible from the upload
UI. See the build-environment note under Setup for the usual cause.

## Local Release Signing

Release signing material must stay local and never be committed.

1. Place your upload keystore on your machine, for example:
  `../release-signing/airgrid-upload.jks` (relative to `airgrid/android/`).
2. Create `airgrid/android/key.properties` with your local values:

```properties
storeFile=../release-signing/airgrid-upload.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

`android/key.properties` is git-ignored and should not be committed.

## Android Permissions

AirGrid requests Nearby Connections permissions at runtime during onboarding.

| Permission | Reason |
| ---------- | ------ |
| `BLUETOOTH` / `BLUETOOTH_ADMIN` | Legacy Bluetooth on API < 31 |
| `BLUETOOTH_SCAN` | Discover nearby Bluetooth devices on API 31+ |
| `BLUETOOTH_ADVERTISE` | Advertise presence on API 31+ |
| `BLUETOOTH_CONNECT` | Connect to nearby devices on API 31+ |
| `NEARBY_WIFI_DEVICES` | Wi-Fi Direct discovery and connection on API 33+ |
| `ACCESS_FINE_LOCATION` | Required by Nearby Connections on older Android versions |

If a permission is permanently denied, the app exposes a shortcut to Android app
settings. Location services may also need to be enabled for Nearby Connections
on some devices and OS versions.

## Multi-Device Testing

1. Install AirGrid on two or more physical Android devices.
2. Keep devices within nearby wireless range.
3. Launch AirGrid on each device and complete onboarding.
4. Start or refresh the mesh and verify peers appear in the mesh status UI.
5. Send public and private messages between devices.
6. Test airplane mode by re-enabling Bluetooth and Wi-Fi while leaving internet
   disconnected.

Google Play Services must be available on each device. Devices without Play
Services will show a blocked Nearby state and cannot start the mesh transport.

## Architecture

The production code is organized by responsibility:

```text
lib/
  app/          Root app shell and routing
  core/         Shared constants, logging, validation, crypto, rate limiting
  data/         Storage and transport adapters
  domain/       Mesh models and routing services
  features/     Flutter UI and Riverpod controllers
```

`main.dart` creates long-lived app services, then injects them through Riverpod
providers:

- `LocalIdentityStore`
- `SqliteMessageRepository`
- `SharedPrefsKnownContactStore`
- `CryptoService`

The UI talks to `ChatController`; `ChatController` talks to
`AirGridMeshService`; `AirGridMeshService` talks to the abstract
`TransportService`.

## Runtime Data Flow

Outbound public message:

1. UI submits text to `ChatController.sendMessage`.
2. `ChatController` validates and sanitizes local content.
3. `AirGridMeshService.sendMessage` validates again at the service boundary.
4. The outbound token bucket is checked.
5. An `AirGridPacket` is created with the local node ID in `seenByNodes`.
6. The message is emitted locally and saved by the controller.
7. The packet is fragmented if needed and sent to connected endpoints.

Inbound packet:

1. Transport emits `TransportBytesReceived`.
2. `AirGridMeshService` applies per-endpoint rate limiting.
3. Bytes are decoded by `TransportCodec`.
4. TTL, loop-prevention, and remote validation gates run.
5. Fragments are reassembled when all chunks arrive.
6. Duplicate packets are suppressed by bounded `LruCache` instances.
7. Accepted packets are emitted to UI streams and may be relayed.
8. Private packets addressed to other nodes may be relayed or spooled.

## Security Model

AirGrid is designed for local, nearby communication. It does not use a central
server.

Security-relevant behavior:

- stable node IDs are UUIDs
- private/public key material is generated locally
- private keys are stored in secure storage
- legacy plaintext key storage is migrated automatically
- private messages prefer encryption when peer keys are known
- remote packet input is validated and malformed packets are dropped
- inbound traffic is rate-limited per peer endpoint
- key announce rebroadcasts have cooldown protection

`LocalIdentityStore` stores node ID and display name in `SharedPreferences`.
X25519 private/public key material is stored in `FlutterSecureStorage` with
Android encrypted shared preferences enabled. On upgrade, legacy key material is
migrated from `SharedPreferences` to secure storage and then removed from the
legacy keys.

`CryptoService` holds the local keypair in memory after startup and caches peer
public keys learned from `key_announce` packets. Encrypted private messages use
X25519 to derive a shared secret, then use ChaCha20-Poly1305 AEAD for message
content. The encrypted wire format is:

```text
base64(nonce[12] + cipherText[n] + mac[16])
```

This protects private message contents from casual relay observers, but it is
not a full authenticated identity system. Stronger long-term identity
verification is future work.

### Key Fingerprints And Key-Change Detection

A node ID is **not** cryptographically bound to its public key. Any peer can
announce any node ID with its own key, so a familiar name in the peer list is
not proof of who is behind it.

Two mitigations exist today:

- `CryptoService.fingerprint` renders a 64-bit SHA-256 fingerprint of a public
  key as four groups of four hex characters. Two users comparing that string
  out-of-band is the only way to confirm a key really belongs to the person
  they think it does — the mesh learns keys over the mesh and cannot vouch for
  them.
- `AirGridMeshService.keyChangeStream` emits whenever a known node ID announces
  a key different from the one previously pinned for it.

A key change is **accepted, not blocked**. A reinstall generates a fresh
identity key, so blocking would break a common, legitimate case; the service
cannot tell a reinstall from an impersonation attempt, so it defers to the
user. Surfacing these events in the UI is still to do.

### Known Gap: Cleartext Metadata On Private Packets

`senderName` and `recipientNodeId` travel in cleartext on encrypted private
packets. Encrypted private packets are also broadcast to *every* connected
endpoint for crowd relay, so this exposes who is talking to whom to every peer
in radio range, not merely to relays along a path.

Omitting `senderName` on private packets is **not** a drop-in change:
`DisplayNameValidator.validateRemote` rejects an empty name, so any node
running a released build would drop such packets at the validation gate and
private messaging would silently break across versions. The rollout is
therefore staged:

- **Phase 1 — shipped.** Receivers accept a packet with no `senderName`
  (`DisplayNameValidator.validateRemoteOptional`) and fall back to the
  known-contact record for display. A *malformed* name is still rejected as
  strictly as before; only absence is tolerated.
- **Phase 2 — not yet.** Once phase 1 is widely deployed, senders stop putting
  `senderName` on private packets. Do not ship this until phase-1 builds have
  had time to reach the field, or private messages from new nodes will vanish
  on older ones.

`recipientNodeId` is a harder problem: routing needs it. Pseudonymous,
rotating recipient tags are the standard answer and would be a wire-format
version bump.

### Verifying A Peer

The peer profile sheet shows a **safety number** — the fingerprint of that
peer's public key. Two people comparing it in person is the only way to know a
key belongs to who they think it does. If it changes later, the peer either
reinstalled or someone is impersonating them; the app cannot tell which.

Do not log private keys, shared secrets, or plaintext private message contents.

## Routing Rules

Important mesh invariants:

- All new local packets start with `seenByNodes: [localNodeId]`.
- Packets with `hopLimit <= 0` are dropped.
- Packets already containing the local node ID in `seenByNodes` are dropped.
- Packet IDs are deduplicated with bounded TTL-aware LRU caches.
- Relay sends exclude the source endpoint.
- Relay jitter is decided by `RelayController`.
- Fragment chunks are deduplicated separately from assembled packets.

Relay eligibility follows two rules, pinned by `relay_eligibility_test.dart`:

- Public traffic relays — `chat`, `image`, `audio`, `key_announce`,
  `location_update`.
- Private traffic relays **only** when encrypted, because a relay must never
  be able to read what it forwards. Plaintext private packets are dropped.

Public walkie audio (`packetType: 'audio'`) relays mesh-wide, matching public
text and images. Clips are bounded by `kWalkieMaxBytes` (96 KiB), and that
bound is currently the only real brake: an 8-hop flood of a 96 KiB clip is far
more traffic than a text packet, and the inbound rate limiter counts *packets*,
not bytes, so it does not throttle media proportionally. Byte-aware rate
limiting is the natural follow-up if public walkie sees heavy use in a crowded
mesh.

Private routing:

- Direct private messages are sent only to the target endpoint.
- Encrypted private packets not addressed to this node may be relayed.
- Plaintext private packets not addressed to this node are dropped.
- Store-and-forward spool entries are keyed by recipient node ID and expire
  quickly.
- Spooled packets flush only when the recipient is identified as a direct peer.

## Validation And Rate Limiting

Validation is layered:

- UI/controllers validate local user input and may sanitize it.
- Service APIs validate again for defense in depth.
- Remote mesh input is strict: malformed data is logged and dropped.

Current validators live in `core/validation.dart`:

- `DisplayNameValidator`: max 32 characters, no control characters, local trim
  and space/tab collapse, strict remote format.
- `MessageContentValidator`: max 8 KiB UTF-8 encoded content, trims local sends,
  allows normal newlines/tabs, rejects other control characters.
- `NodeIdValidator`: strict UUID-format node IDs only.

Rate limiting uses token buckets in `core/rate_limiter.dart`. Current limits
are defined in `AirGridConstants`:

- Outbound user messages: 5/sec sustained, burst 10.
- Inbound packets: 10/sec sustained, burst 20 per endpoint.
- Key announce cooldown: 5 seconds per node ID / public key pair.
- Read receipt batches: 1/sec sustained, burst 3 per peer.
- Idle limiter eviction: 5 minutes.

## Persistence

Messages are persisted with SQLite. Recent history is loaded at startup and
retention pruning keeps the local database bounded. Known contacts are persisted
separately so private messages can be sent to previously discovered peers when
they are not directly connected.

## Fragmentation

`PacketFragmenter` splits encoded packets larger than
`AirGridConstants.kFragmentThreshold` into `fragment` packets and reassembles
them by `fragmentOf`.

Fragment packets intentionally share the original packet's immutable
`seenByNodes` list. Relay operations that modify `seenByNodes` must create a
new list with a spread operation.

## Attachment Encoding And Size Budget

Attachments are base64-encoded **three times** before they reach the radio:

1. raw bytes → base64 inside the JSON envelope (`media_attachment.dart`) — 4/3
2. envelope → `CryptoService.encryptContent` → `base64(nonce‖ct‖mac)` — 4/3
3. encoded packet → base64 per fragment chunk (`PacketFragmenter`) — 4/3

Net wire expansion is roughly **2.4×**, and a file at the current cap produces
on the order of 1,800 fragments.

Because `PacketFragmenter.fragment` encodes the *whole* packet before
splitting, an oversize attachment fails at `TransportCodec.encode`, not at send
time. Attachment caps are therefore **derived from `kMaxPacketBytes`**, not
chosen independently:

```text
raw_bytes × (4/3) + envelope_overhead + AEAD_overhead, × (4/3) < kMaxPacketBytes
```

`mesh_service_oversize_file_test.dart` asserts this invariant. If you raise an
attachment cap, raise `kMaxPacketBytes` with it or the test will fail — which
is the intent.

A packet that cannot be encoded is a **permanent** failure. It raises
`PacketTooLargeException`, is reported as `DeliveryStatus.failed`, and is never
spooled: spooling an unencodable packet pins an entry that can never drain.

Replacing this chain with native Nearby Connections `FILE`/`STREAM` payloads
would remove all three base64 layers and the in-memory reassembly. That work is
tracked under Future Work.

## Development Checks

Before merging changes, run:

```bash
flutter analyze
flutter test
```

CI runs `dart format`, `flutter analyze`, and `flutter test` on every push and
pull request (`.github/workflows/ci.yml`). A second job fails the build if
signing material (`*.jks`, `*.keystore`, `key.properties`) or device logs are
ever tracked in git.

The test suite covers routing, validation, crypto behavior, secure key
migration, SQLite migrations, fragmentation, rate limiting, controller startup,
and widget flows.

When changing mesh behavior, confirm:

- malformed remote input is rejected, not sanitized
- private keys and plaintext private content are not logged
- node IDs remain UUID-only
- relays never echo to the source endpoint
- direct key announce enrichment still works
- tests use deterministic UUID fixtures instead of short fake IDs
- migrations preserve existing user identity and message data

## Known Limitations

- Nearby Connections performance varies by device, OS version, and radio
  conditions.
- Mesh stability degrades as the number of simultaneous nearby peers grows.
- Google Play Services is required.
- iOS is not supported.
- Encrypted private messaging depends on peers learning each other's public keys
  through key announcements.
- Store-and-forward spool entries are intentionally short-lived and bounded.

## Future Work

- richer private-thread UX
- native Nearby `FILE`/`STREAM` payloads for attachments, replacing the
  base64 + fragment chain
- key-fingerprint verification and trust-on-first-use key pinning
- forward secrecy (current design is static-static X25519: one shared secret
  per peer pair, for the lifetime of both identities)
- metadata minimisation — `senderName` and `recipientNodeId` are currently
  cleartext to relays on encrypted private packets
- stronger long-term identity verification
- broader type-safe ID migration
- additional database indices when conversation-specific query patterns require
  them
- APK distribution over Nearby Connections

APK distribution is not implemented. Any future APK sharing must be Android-only,
explicitly user-mediated, point-to-point rather than mesh-routed, and include
SHA-256 integrity verification before the user manually installs the received
APK. This feature may also have Google Play policy implications and should be
reviewed before shipping.

## License

MIT
