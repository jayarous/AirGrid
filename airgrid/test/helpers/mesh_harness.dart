import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_identity.dart';
import 'fake_transport.dart';

/// A single in-process mesh node used by [FakeMeshHarness].
class FakeMeshNode {
  final String nodeId;
  final String displayName;
  final FakeTransport transport;
  final CryptoService crypto;
  final AirGridMeshService service;
  final InMemoryKnownContactStore store;

  const FakeMeshNode({
    required this.nodeId,
    required this.displayName,
    required this.transport,
    required this.crypto,
    required this.service,
    required this.store,
  });
}

/// In-process multi-node mesh for integration testing.
///
/// Each node has its own [FakeTransport], [CryptoService],
/// [InMemoryKnownContactStore], and [AirGridMeshService].  The harness routes
/// packets between them via [settle].
///
/// Usage:
/// ```dart
/// final harness = FakeMeshHarness();
/// final nodeA = await harness.addNode(identA);
/// final nodeB = await harness.addNode(identB);
/// await harness.connect(identA.nodeId, identB.nodeId);
/// await nodeA.service.sendMessage('hello');
/// await harness.settle();
/// // nodeB's stream now has the message.
/// await harness.dispose();
/// ```
class FakeMeshHarness {
  final _nodes = <String, FakeMeshNode>{};

  // _sendMap[endpointId] = ({destNodeId, fromEp})
  // When the owning node sends bytes to `endpointId`, the harness delivers
  // those bytes to `destNodeId`'s transport with `fromEp` as the source
  // endpoint ID.
  final _sendMap = <String, ({String destNodeId, String fromEp})>{};

  Map<String, FakeMeshNode> get nodes => Map.unmodifiable(_nodes);

  // ---------------------------------------------------------------------------
  // Node lifecycle
  // ---------------------------------------------------------------------------

  /// Creates a mesh node for [identity] and registers it with this harness.
  ///
  /// Each call resets the SharedPreferences mock so that [LocalIdentityStore]
  /// picks up the correct node ID and keypair.  Already-created nodes retain
  /// their own prefs reference and are unaffected.
  ///
  /// [spoolClock] overrides the store-and-forward TTL clock; pass a mutable
  /// closure to advance time in spool TTL tests.
  Future<FakeMeshNode> addNode(
    CryptoTestIdentity identity, {
    DateTime Function()? spoolClock,
  }) async {
    SharedPreferences.setMockInitialValues({
      'airgrid_node_id': identity.nodeId,
      'airgrid_display_name': identity.displayName,
    });
    FlutterSecureStorage.setMockInitialValues({
      'airgrid_secure_private_key_b64': identity.privateKeyBase64,
      'airgrid_secure_public_key_b64': identity.publicKeyBase64,
    });
    final localStore = await LocalIdentityStore.create();

    final crypto = CryptoService();
    await crypto.loadLocalKeyPair(
      identity.privateKeyBase64,
      identity.publicKeyBase64,
    );

    final contactStore = InMemoryKnownContactStore();
    final transport = FakeTransport();
    final service = AirGridMeshService(
      transport,
      localStore,
      crypto,
      jitterOverrideMs: 0,
      spoolClock: spoolClock,
      contactStore: contactStore,
      privacyStore: InMemoryPrivacySettingsStore(),
    );

    // Allow stream subscriptions to wire up before tests interact.
    await Future<void>.delayed(Duration.zero);

    final node = FakeMeshNode(
      nodeId: identity.nodeId,
      displayName: identity.displayName,
      transport: transport,
      crypto: crypto,
      service: service,
      store: contactStore,
    );
    _nodes[identity.nodeId] = node;
    return node;
  }

  // ---------------------------------------------------------------------------
  // Topology management
  // ---------------------------------------------------------------------------

  /// Connects [nodeAId] and [nodeBId] bidirectionally, then exchanges
  /// key_announces so both sides cache each other's public keys.
  Future<void> connect(String nodeAId, String nodeBId) async {
    _wire(nodeAId, nodeBId);
    await Future<void>.delayed(Duration.zero);
    await _nodes[nodeAId]!.service.sendKeyAnnounce();
    await _nodes[nodeBId]!.service.sendKeyAnnounce();
    await settle();
  }

  /// Connects [nodeAId] and [nodeBId] without triggering key_announces.
  ///
  /// Use this to test relayed key_announce scenarios where the two nodes
  /// should not have each other's keys from a direct exchange.
  Future<void> connectSilent(String nodeAId, String nodeBId) async {
    _wire(nodeAId, nodeBId);
    await Future<void>.delayed(Duration.zero);
  }

  void _wire(String nodeAId, String nodeBId, {bool withNodeId = false}) {
    final nodeA = _nodes[nodeAId]!;
    final nodeB = _nodes[nodeBId]!;

    // epAB: the endpoint handle A uses to address B.
    // epBA: the endpoint handle B uses to address A.
    final epAB = epId(nodeAId, nodeBId);
    final epBA = epId(nodeBId, nodeAId);

    _sendMap[epAB] = (destNodeId: nodeBId, fromEp: epBA);
    _sendMap[epBA] = (destNodeId: nodeAId, fromEp: epAB);

    // By default do NOT pass nodeId so that:
    //   • MeshPeer.nodeId starts null → encryptionReady = false
    //   • _markDirectPeerReady runs fully on the first key_announce
    //   • _flushSpool is triggered correctly after a direct key exchange
    // Use withNodeId: true only when you need peer.nodeId set at connection
    // time without waiting for a key_announce (e.g. plaintext-fallback tests).
    nodeA.transport.connectPeer(
      epAB,
      name: nodeB.displayName,
      nodeId: withNodeId ? nodeBId : null,
    );
    nodeB.transport.connectPeer(
      epBA,
      name: nodeA.displayName,
      nodeId: withNodeId ? nodeAId : null,
    );
  }

  /// Connects [nodeAId] and [nodeBId] without key_announces, but registers
  /// each side's nodeId in the other's peer table at connection time.
  ///
  /// Use this when you need [MeshPeer.nodeId] to be non-null before a
  /// key_announce occurs (e.g. to test plaintext-fallback behaviour).
  Future<void> connectSilentWithId(String nodeAId, String nodeBId) async {
    _wire(nodeAId, nodeBId, withNodeId: true);
    await Future<void>.delayed(Duration.zero);
  }

  /// Disconnects [nodeAId] and [nodeBId] and lets disconnect events propagate.
  Future<void> disconnect(String nodeAId, String nodeBId) async {
    final nodeA = _nodes[nodeAId]!;
    final nodeB = _nodes[nodeBId]!;

    final epAB = epId(nodeAId, nodeBId);
    final epBA = epId(nodeBId, nodeAId);

    nodeA.transport.disconnectPeer(epAB);
    nodeB.transport.disconnectPeer(epBA);

    _sendMap.remove(epAB);
    _sendMap.remove(epBA);

    await Future<void>.delayed(Duration.zero);
  }

  /// Returns the endpoint handle that [ownerNodeId] uses to address [peerNodeId].
  String epId(String ownerNodeId, String peerNodeId) =>
      'ep_${ownerNodeId}_$peerNodeId';

  // ---------------------------------------------------------------------------
  // Packet routing
  // ---------------------------------------------------------------------------

  /// Routes all pending outbound packets until the mesh is quiet or
  /// [maxRounds] is reached.
  ///
  /// Each round:
  /// 1. Snapshots and clears every node's [FakeTransport.sentPayloads].
  /// 2. Delivers each payload to the destination node.
  /// 3. Awaits a zero-timer to flush async handlers.
  /// 4. Repeats only if at least one packet was delivered.
  Future<void> settle({int maxRounds = 10}) async {
    for (int round = 0; round < maxRounds; round++) {
      bool anyDelivered = false;

      for (final node in _nodes.values) {
        if (node.transport.sentPayloads.isEmpty) continue;

        final pending = List.of(node.transport.sentPayloads);
        node.transport.sentPayloads.clear();

        for (final sent in pending) {
          for (final ep in sent.endpoints) {
            final route = _sendMap[ep];
            if (route == null) continue;
            final dest = _nodes[route.destNodeId];
            if (dest == null) continue;
            dest.transport.receiveBytes(route.fromEp, sent.bytes);
            anyDelivered = true;
          }
        }
      }

      // Give async handlers (decryption, relay decisions) time to complete.
      await Future<void>.delayed(Duration.zero);
      if (!anyDelivered) break;
    }
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    for (final node in _nodes.values) {
      await node.service.dispose();
      node.transport.dispose();
      await node.store.dispose();
    }
    _nodes.clear();
    _sendMap.clear();
  }
}
