import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

/// Regression tests for the oversize-file silent failure.
///
/// A private file is encoded three times before it reaches the wire:
///   1. raw bytes -> base64 inside the JSON envelope  (~1.33x)
///   2. envelope  -> encrypt -> base64(nonce|ct|mac)  (~1.33x)
///   3. encoded packet -> base64 per fragment chunk   (~1.33x)
///
/// Steps 1 and 2 happen before [PacketFragmenter.fragment], which calls
/// [TransportCodec.encode] on the *whole* packet. That encode throws
/// [ArgumentError] above [AirGridConstants.kMaxPacketBytes], so a file near
/// the UI cap of [AirGridConstants.kPrivateFileMaxBytes] cannot be sent at all.
///
/// The bug is that the throw was caught by a bare `catch (_)` and reported as
/// a successful encrypted send, leaving the packet in the spool to re-throw
/// forever. These tests pin the corrected behaviour: a real failure.
final _localNodeId = testNodeId('local');
const _peerNodeId = 'peer-oversize';

Future<LocalIdentityStore> _makeIdentity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': _localNodeId,
    'airgrid_display_name': 'LocalUser',
  });
  return LocalIdentityStore.create();
}

FileAttachmentPayload _fileOfSize(int rawBytes) {
  final data = Uint8List(rawBytes); // zero-filled; base64 expansion is uniform
  return FileAttachmentPayload(
    transferId: 'transfer-oversize',
    fileName: 'big.bin',
    mimeType: 'application/octet-stream',
    byteLength: rawBytes,
    dataBase64: base64Encode(data),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport transport;
  late LocalIdentityStore identity;
  late CryptoService crypto;
  late AirGridMeshService mesh;
  late MeshPeer peer;

  setUp(() async {
    transport = FakeTransport();
    identity = await _makeIdentity();

    crypto = CryptoService();
    await crypto.loadLocalKeyPair(
      identity.privateKeyBase64!,
      identity.publicKeyBase64!,
    );
    final peerKeyPair = await X25519().newKeyPair();
    final peerPublicKey = await peerKeyPair.extractPublicKey();
    crypto.cacheKey(_peerNodeId, base64Encode(peerPublicKey.bytes));

    mesh = AirGridMeshService(transport, identity, crypto, jitterOverrideMs: 0);
    await Future<void>.delayed(Duration.zero);

    transport.connectPeer('ep-target');
    await Future<void>.delayed(Duration.zero);

    peer = MeshPeer(
      endpointId: 'ep-target',
      displayName: 'OversizePeer',
      connectedAt: DateTime.now(),
      nodeId: _peerNodeId,
      encryptionReady: true,
    );
  });

  tearDown(() async {
    await mesh.dispose();
  });

  group('oversize private file', () {
    test(
      'a file at the UI cap must not be reported as sent',
      () async {
        // 4.8 MB is under kPrivateFileMaxBytes (5 MB) so the UI allows it,
        // but exceeds what the encode chain can carry.
        final file = _fileOfSize(4800 * 1024);

        final statuses = <DeliveryStatus>[];
        final sub = mesh.statusStream.listen((e) => statuses.add(e.status));

        final result = await mesh.sendPrivateFile(peer, file);
        await Future<void>.delayed(Duration.zero);

        expect(
          result,
          PrivateSendResult.failed,
          reason: 'an unencodable packet must never report success',
        );
        expect(
          statuses,
          isNot(contains(DeliveryStatus.sent)),
          reason: 'the bubble must not show as sent',
        );
        expect(statuses, contains(DeliveryStatus.failed));
        expect(
          transport.sentPayloads,
          isEmpty,
          reason: 'nothing should reach the transport',
        );

        await sub.cancel();
      },
    );

    test('a small file still sends encrypted', () async {
      final file = _fileOfSize(64 * 1024);

      final result = await mesh.sendPrivateFile(peer, file);

      expect(result, PrivateSendResult.sentEncrypted);
      expect(transport.sentPayloads, isNotEmpty);
    });

    test(
      'size caps are arithmetically coherent with the packet ceiling',
      () {
        // Two base64 layers apply before the codec size check. If this fails,
        // the UI cap permits files the pipeline cannot carry.
        const b64 = 4 / 3;
        const aeadOverhead = 28; // nonce[12] + mac[16]
        const envelopeOverhead = 512; // JSON keys, transferId, fileName, mime

        final worstCaseContent =
            ((AirGridConstants.kPrivateFileMaxBytes * b64 + envelopeOverhead) +
                    aeadOverhead) *
                b64;

        expect(
          worstCaseContent,
          lessThan(AirGridConstants.kMaxPacketBytes),
          reason:
              'kPrivateFileMaxBytes (${AirGridConstants.kPrivateFileMaxBytes}) '
              'expands to ~${worstCaseContent.round()} bytes of packet '
              'content, which exceeds kMaxPacketBytes '
              '(${AirGridConstants.kMaxPacketBytes}). Lower the file cap or '
              'raise the packet ceiling.',
        );
      },
    );
  });
}
