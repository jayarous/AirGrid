import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/core/rider_audio_bridge.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

class _StubMessageRepository implements MessageRepository {
  /// History this fake pretends to hold. Empty unless a test seeds it.
  final List<AirGridMessage> seeded;

  _StubMessageRepository({this.seeded = const []});

  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async =>
      seeded.take(limit).toList();

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}
}

Entitlement _plus() => SubscriptionCatalog.entitlementFor(
  purchaseToken: 'token-abc',
  verifiedAt: _now,
  period: BillingPeriod.monthly,
);

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': testNodeId('local'),
    'airgrid_display_name': 'TestUser',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

Future<({ProviderContainer container, InMemoryKnownContactStore contacts})>
_harness({
  Entitlement entitlement = Entitlement.free,
  bool publicWalkieEnabled = false,
  List<AirGridMessage> messages = const [],
}) async {
  final identity = await _identity();
  final contacts = InMemoryKnownContactStore();
  final container = ProviderContainer(
    overrides: [
      localIdentityStoreProvider.overrideWithValue(identity),
      messageRepositoryProvider.overrideWithValue(
        _StubMessageRepository(seeded: messages),
      ),
      transportServiceProvider.overrideWithValue(FakeTransport()),
      playServicesProvider.overrideWithValue(
        FakePlayServices(const PlayServicesStatus.available()),
      ),
      foregroundServiceProvider.overrideWithValue(FakeForegroundService()),
      cryptoServiceProvider.overrideWithValue(CryptoService()),
      knownContactStoreProvider.overrideWithValue(contacts),
      localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
      privacySettingsStoreProvider.overrideWithValue(
        InMemoryPrivacySettingsStore(),
      ),
      publicWalkieSettingsStoreProvider.overrideWithValue(
        InMemoryPublicWalkieSettingsStore(initialEnabled: publicWalkieEnabled),
      ),
      chatListPreferencesStoreProvider.overrideWithValue(
        InMemoryChatListPreferencesStore(),
      ),
      batterySettingsStoreProvider.overrideWithValue(
        InMemoryBatterySettingsStore(),
      ),
      entitlementStoreProvider.overrideWithValue(
        InMemoryEntitlementStore(initial: entitlement, clock: () => _now),
      ),
      // Keeps Rider Mode off the real audio platform channel.
      riderAudioPlaybackProvider.overrideWithValue(
        const NoopRiderAudioPlayback(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, contacts: contacts);
}

MeshPeer _peer() => MeshPeer(
  endpointId: 'ep-1',
  displayName: 'Peer',
  nodeId: testNodeId('peer'),
  connectedAt: _now,
);

KnownContact _contact({bool walkieAlwaysOn = false}) => KnownContact(
  nodeId: testNodeId('peer'),
  displayName: 'Peer',
  publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  lastSeenAt: _now,
  isTrusted: true,
  walkieAlwaysOn: walkieAlwaysOn,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('starting a walkie session', () {
    test('is refused on the free tier', () async {
      final h = await _harness();
      final ok = await h.container
          .read(chatControllerProvider.notifier)
          .sendWalkieInvite(_peer());
      expect(ok, isFalse);
    });

    test('is not refused by the gate on Plus', () async {
      // It may still fail for mesh reasons; what matters is that the gate is
      // no longer what stops it.
      final h = await _harness(entitlement: _plus());
      expect(
        h.container.read(featureGatesProvider).canStartWalkieSession,
        isTrue,
      );
    });
  });

  group('accepting is never gated', () {
    test('every join-side gate is open on the free tier', () async {
      // The load-bearing invariant. If a free peer could not accept, a paying
      // user's headline feature would only work when the other person had also
      // paid — and the payer would blame the app, not the paywall.
      final h = await _harness();
      final gates = h.container.read(featureGatesProvider);

      expect(gates.isPlus, isFalse);
      expect(gates.canAcceptWalkieSession, isTrue);
      expect(gates.canDeclineWalkieSession, isTrue);
      expect(gates.canEndWalkieSession, isTrue);
      expect(gates.canAcceptRiderSession, isTrue);
      expect(gates.canArmRiderPresence, isTrue);
      expect(gates.canRelayWalkieAudio, isTrue);
    });
  });

  group('public walkie', () {
    test('can be switched on without Plus', () async {
      // Public walkie is free. This assertion is the inverse of the one it
      // replaced, kept rather than deleted so that re-gating breaks a test
      // instead of passing quietly.
      final h = await _harness();
      final controller = h.container.read(chatControllerProvider.notifier);

      await controller.setPublicWalkieStayOnline(true);

      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isTrue,
      );
    });

    test('can always be switched off, even lapsed', () async {
      // Never leave a lapsed subscriber stuck broadcasting.
      final h = await _harness(entitlement: _plus());
      final controller = h.container.read(chatControllerProvider.notifier);
      await controller.setPublicWalkieStayOnline(true);
      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isTrue,
      );

      // Simulate the subscription lapsing mid-session.
      await h.container.read(entitlementStoreProvider).save(Entitlement.free);
      await controller.setPublicWalkieStayOnline(false);

      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isFalse,
      );
    });

    test('switches on with Plus', () async {
      final h = await _harness(entitlement: _plus());
      await h.container
          .read(chatControllerProvider.notifier)
          .setPublicWalkieStayOnline(true);

      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isTrue,
      );
    });

    test('a saved setting is restored on the free tier', () async {
      // This once asserted the opposite: while public walkie was paid, a
      // preference saved in an older build had to be re-gated on restore,
      // because the toggle only consults a gate on the way *on*.
      //
      // Now that it is free there is nothing to re-check, and the user's
      // stored choice must simply come back.
      final h = await _harness(publicWalkieEnabled: true);

      h.container.read(chatControllerProvider.notifier);
      await pumpEventQueue();

      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isTrue,
      );
    });

    test('a saved setting is restored for a subscriber', () async {
      final h = await _harness(entitlement: _plus(), publicWalkieEnabled: true);

      h.container.read(chatControllerProvider.notifier);
      await pumpEventQueue();

      expect(
        h.container.read(chatControllerProvider).walkie.publicStayOnline,
        isTrue,
      );
    });
  });

  group('walkie always-on', () {
    Future<void> seedContact(InMemoryKnownContactStore contacts) =>
        contacts.upsert(_contact());

    test('cannot be enabled without Plus', () async {
      final h = await _harness();
      await seedContact(h.contacts);

      await h.container
          .read(chatControllerProvider.notifier)
          .setWalkieAlwaysOn(testNodeId('peer'), true);

      expect(h.contacts.isWalkieAlwaysOn(testNodeId('peer')), isFalse);
    });

    test('can be disabled without Plus', () async {
      final h = await _harness(entitlement: _plus());
      await seedContact(h.contacts);
      final controller = h.container.read(chatControllerProvider.notifier);
      await controller.setWalkieAlwaysOn(testNodeId('peer'), true);
      expect(h.contacts.isWalkieAlwaysOn(testNodeId('peer')), isTrue);

      await h.container.read(entitlementStoreProvider).save(Entitlement.free);
      await controller.setWalkieAlwaysOn(testNodeId('peer'), false);

      expect(h.contacts.isWalkieAlwaysOn(testNodeId('peer')), isFalse);
    });
  });

  group('message history export', () {
    AirGridMessage message({
      required String id,
      required String content,
      String messageKind = 'text',
    }) => AirGridMessage(
      id: id,
      senderNodeId: testNodeId('peer'),
      senderName: 'Peer',
      timestamp: _now,
      content: content,
      isLocal: false,
      messageKind: messageKind,
    );

    test('is refused on the free tier', () async {
      final h = await _harness(
        messages: [message(id: 'm1', content: 'hello')],
      );

      final transcript = await h.container
          .read(chatControllerProvider.notifier)
          .exportMessageHistory();

      expect(
        transcript,
        isNull,
        reason: 'null means refused — distinct from an empty history',
      );
    });

    test('produces a transcript on Plus', () async {
      final h = await _harness(
        entitlement: _plus(),
        messages: [message(id: 'm1', content: 'hello')],
      );

      final transcript = await h.container
          .read(chatControllerProvider.notifier)
          .exportMessageHistory();

      expect(transcript, isNotNull);
      expect(transcript, contains('hello'));
      expect(transcript, contains('AirGrid message history'));
    });

    test('an empty history reads as empty, not as refused', () async {
      // The two answers send the caller down different paths: one opens the
      // paywall, the other says "you have no messages yet".
      final h = await _harness(entitlement: _plus());

      final transcript = await h.container
          .read(chatControllerProvider.notifier)
          .exportMessageHistory();

      expect(transcript, isNotNull);
      expect(transcript, isEmpty);
    });

    test('leaves walkie clips out of the transcript', () async {
      // Push-to-talk audio was never part of a readable conversation, and is
      // already filtered out of loaded history.
      final h = await _harness(
        entitlement: _plus(),
        messages: [
          message(id: 'm1', content: 'a real message'),
          message(id: 'm2', content: '[walkie]', messageKind: 'audio'),
        ],
      );

      final transcript = await h.container
          .read(chatControllerProvider.notifier)
          .exportMessageHistory();

      expect(transcript, contains('a real message'));
      expect(transcript, isNot(contains('walkie')));
    });

    test('a history of only walkie clips exports as empty', () async {
      final h = await _harness(
        entitlement: _plus(),
        messages: [
          message(id: 'm1', content: '[walkie]', messageKind: 'audio'),
        ],
      );

      final transcript = await h.container
          .read(chatControllerProvider.notifier)
          .exportMessageHistory();

      expect(
        transcript,
        isEmpty,
        reason: 'filtering everything out must not share a header-only file',
      );
    });
  });

  group('file attachments', () {
    test('are refused on the free tier without reaching the mesh', () async {
      final h = await _harness();
      final result = await h.container
          .read(chatControllerProvider.notifier)
          .sendPrivateFile(
            _peer(),
            const FileAttachmentPayload(
              transferId: 'transfer-1',
              fileName: 'notes.txt',
              mimeType: 'text/plain',
              byteLength: 4,
              dataBase64: 'AAAA',
            ),
          );

      expect(result, PrivateSendResult.failed);
    });

    test('images and voice notes stay free', () async {
      final h = await _harness();
      final gates = h.container.read(featureGatesProvider);
      expect(gates.canSendImage, isTrue);
      expect(gates.canSendVoiceNote, isTrue);
      expect(gates.canSendFileAttachment, isFalse);
    });
  });

  group('walkie audio transmit', () {
    AudioAttachmentPayload audio({required String source}) =>
        AudioAttachmentPayload(
          transferId: 'transfer-1',
          mimeType: 'audio/m4a',
          byteLength: 4,
          durationMs: 1200,
          source: source,
          dataBase64: 'AAAA',
        );

    test('public broadcast is allowed on the free tier', () async {
      // The inverse of the assertion this replaces, kept so that re-gating
      // public broadcast fails a test rather than passing quietly.
      //
      // Broadcast is still bounded — by the airtime budget in the mesh
      // service, which applies to every tier. See
      // test/domain/mesh_service_public_airtime_test.dart.
      final h = await _harness();
      await expectLater(
        h.container
            .read(chatControllerProvider.notifier)
            .sendPublicWalkieAudio(
              audio(source: AudioAttachmentPayload.sourceWalkie),
            ),
        completes,
      );
    });

    test(
      'private walkie is refused outside a session on the free tier',
      () async {
        // Otherwise the invite gate is bypassed by picking a target and pressing
        // the button.
        final h = await _harness();
        final result = await h.container
            .read(chatControllerProvider.notifier)
            .sendPrivateAudio(
              _peer(),
              audio(source: AudioAttachmentPayload.sourceWalkie),
            );

        expect(result, PrivateSendResult.failed);
      },
    );

    test('a free peer CAN talk back inside an accepted session', () async {
      // The load-bearing case. If this ever fails, a paying user's walkie only
      // works when the other person has also paid.
      final h = await _harness();
      final notifier = h.container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        walkie: notifier.state.walkie.copyWith(
          sessionActivePeerNodeId: testNodeId('peer'),
        ),
      );

      expect(
        h.container
            .read(featureGatesProvider)
            .canTransmitPrivateWalkie(inActiveSession: true),
        isTrue,
      );
      final result = await notifier.sendPrivateAudio(
        _peer(),
        audio(source: AudioAttachmentPayload.sourceWalkie),
      );

      expect(
        result,
        isNot(PrivateSendResult.failed),
        reason: 'a free peer must be able to reply for the whole session',
      );
    });

    test('voice notes are never gated, session or not', () async {
      final h = await _harness();
      final result = await h.container
          .read(chatControllerProvider.notifier)
          .sendPrivateAudio(
            _peer(),
            audio(source: AudioAttachmentPayload.sourceVoiceNote),
          );

      expect(
        result,
        isNot(PrivateSendResult.failed),
        reason: 'a voice note is a chat message, and chat is free',
      );
    });
  });

  group('Rider Mode', () {
    test('arming presence works on the free tier', () async {
      // Arming is how paying riders discover this peer, and it travels inside a
      // key_announce packet. Gating it would break the feature for subscribers
      // and change the wire at the same time.
      final h = await _harness();
      await h.container
          .read(riderModeControllerProvider.notifier)
          .armPresence(true);

      expect(h.container.read(riderModeControllerProvider).isArmed, isTrue);
    });

    test('starting a session is refused on the free tier', () async {
      final h = await _harness();
      await h.container
          .read(riderModeControllerProvider.notifier)
          .startSession(_peer());

      final state = h.container.read(riderModeControllerProvider);
      expect(state.isActive, isFalse);
      expect(state.isStarting, isFalse);
    });
  });
}
