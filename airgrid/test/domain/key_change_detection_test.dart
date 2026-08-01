import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

/// Trust-on-first-use detection for key_announce.
///
/// A node ID is not cryptographically bound to its public key, so a key
/// change is indistinguishable from an impersonation attempt. The service
/// accepts the new key — blocking would break every legitimate reinstall —
/// and emits on [AirGridMeshService.keyChangeStream] so the user can judge.
final _localNodeId = testNodeId('local');
final _peerNodeId = testNodeId('peer');

String _keyOf(int fill) => base64Encode(Uint8List(32)..fillRange(0, 32, fill));

AirGridPacket _announce(String publicKey, {String name = 'Alex'}) =>
    AirGridPacket(
      messageId: 'ka-${publicKey.hashCode}',
      senderNodeId: _peerNodeId,
      senderName: name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: '',
      seenByNodes: [_peerNodeId],
      hopLimit: 8,
      packetType: 'key_announce',
      senderPublicKey: publicKey,
    );

void main() {
  late FakeTransport transport;
  late AirGridMeshService mesh;
  late InMemoryKnownContactStore contacts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'airgrid_node_id': _localNodeId,
      'airgrid_display_name': 'LocalUser',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final identity = await LocalIdentityStore.create();
    contacts = InMemoryKnownContactStore();
    transport = FakeTransport();
    mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: contacts,
    );
    await Future<void>.delayed(Duration.zero);
    transport.connectPeer('ep-1');
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await mesh.dispose();
    transport.dispose();
  });

  test('first key for an unknown node does not raise a change', () async {
    final events = <dynamic>[];
    final sub = mesh.keyChangeStream.listen(events.add);

    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(1))));
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty, reason: 'nothing was pinned before this');
    await sub.cancel();
  });

  test('re-announcing the same key does not raise a change', () async {
    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(1))));
    await Future<void>.delayed(Duration.zero);

    final events = <dynamic>[];
    final sub = mesh.keyChangeStream.listen(events.add);

    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(1))));
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await sub.cancel();
  });

  test('a different key for a known node raises a change', () async {
    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(1))));
    await Future<void>.delayed(Duration.zero);

    final events = <dynamic>[];
    final sub = mesh.keyChangeStream.listen(events.add);

    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(2))));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.nodeId, _peerNodeId);
    expect(events.single.previousPublicKeyBase64, _keyOf(1));
    expect(events.single.newPublicKeyBase64, _keyOf(2));
    await sub.cancel();
  });

  test('the new key is still accepted after a change', () async {
    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(1))));
    await Future<void>.delayed(Duration.zero);
    transport.receiveBytes('ep-1', TransportCodec.encode(_announce(_keyOf(2))));
    await Future<void>.delayed(Duration.zero);

    // Blocking the new key would break every legitimate reinstall, so the
    // contract is accept-and-warn, not reject.
    final stored = contacts.contacts.firstWhere((c) => c.nodeId == _peerNodeId);
    expect(stored.publicKeyBase64, _keyOf(2));
  });
}
