import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/walkie/walkie_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _NoopMessageRepository implements MessageRepository {
  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async => [];

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}
}

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': 'local-node',
    'airgrid_display_name': 'Jay',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

Future<void> _pumpWalkie(
  WidgetTester tester, {
  FakeTransport? transport,
  FakeForegroundService? foreground,
  KnownContactStore? knownContactStore,
}) async {
  final fg = foreground ?? FakeForegroundService();
  final tx = transport ?? FakeTransport();
  addTearDown(fg.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localIdentityStoreProvider.overrideWithValue(await _identity()),
        messageRepositoryProvider.overrideWithValue(_NoopMessageRepository()),
        transportServiceProvider.overrideWithValue(tx),
        playServicesProvider.overrideWithValue(
          FakePlayServices(const PlayServicesStatus.available()),
        ),
        foregroundServiceProvider.overrideWithValue(fg),
        cryptoServiceProvider.overrideWithValue(CryptoService()),
        knownContactStoreProvider.overrideWithValue(
          knownContactStore ?? InMemoryKnownContactStore(),
        ),
        localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
        privacySettingsStoreProvider.overrideWithValue(
          InMemoryPrivacySettingsStore(),
        ),
        batterySettingsStoreProvider.overrideWithValue(
          InMemoryBatterySettingsStore(),
        ),
      ],
      child: const MaterialApp(home: WalkieScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fits compact screens without page scrolling', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await _pumpWalkie(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(WalkieScreen),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.vertical,
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('shows no-target presence state by default', (tester) async {
    await _pumpWalkie(tester);

    expect(find.text('Private target'), findsOneWidget);
    expect(
      find.text('Choose someone nearby to start a private walkie.'),
      findsOneWidget,
    );
    expect(find.text('Choose person'), findsOneWidget);
    expect(find.text('CHOOSE SOMEONE'), findsOneWidget);
  });

  testWidgets('public walkie icon toggles public online state', (tester) async {
    await _pumpWalkie(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );
    expect(
      container.read(chatControllerProvider).publicWalkieStayOnline,
      isFalse,
    );

    await tester.tap(find.byTooltip('Turn public walkie online'));
    await tester.pumpAndSettle();

    expect(
      container.read(chatControllerProvider).publicWalkieStayOnline,
      isTrue,
    );

    await tester.tap(find.byTooltip('Turn public walkie offline'));
    await tester.pumpAndSettle();

    expect(
      container.read(chatControllerProvider).publicWalkieStayOnline,
      isFalse,
    );
  });

  testWidgets('shows selected private target name', (tester) async {
    await _pumpWalkie(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );

    container
        .read(chatControllerProvider.notifier)
        .selectConversation(
          const PrivateConversation(peerNodeId: 'peer-1', peerName: 'Alex'),
        );
    await tester.pump();

    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Alex is not online yet.'), findsWidgets);
    expect(find.text('Invite'), findsOneWidget);
    expect(find.text('INVITE FIRST'), findsOneWidget);
  });

  testWidgets('shows target online when selected peer is connected', (
    tester,
  ) async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    await _pumpWalkie(tester, transport: transport, foreground: foreground);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );
    final controller = container.read(chatControllerProvider.notifier);

    await controller.startMesh();
    controller.selectConversation(
      const PrivateConversation(peerNodeId: 'peer-1', peerName: 'Alex'),
    );
    transport.connectPeer('endpoint-1', name: 'Alex', nodeId: 'peer-1');
    await tester.pump();

    expect(find.text('Invite'), findsOneWidget);
    expect(
      find.text('Tap Invite to start a private session with Alex.'),
      findsOneWidget,
    );
  });

  testWidgets('renders walkie last error from controller state', (
    tester,
  ) async {
    await _pumpWalkie(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );

    container
        .read(chatControllerProvider.notifier)
        .setWalkieLastError('Peer is not online');
    await tester.pumpAndSettle();

    expect(find.text('Peer is not online'), findsOneWidget);
  });

  testWidgets('choose target button is disabled while walkie is sending', (
    tester,
  ) async {
    await _pumpWalkie(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );

    container
        .read(chatControllerProvider.notifier)
        .setWalkieSending(isSending: true);
    await tester.pump();

    final chooseButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose person'),
    );
    expect(chooseButton.onPressed, isNull);
  });

  testWidgets('choose target shows no-peers snackbar when list is empty', (
    tester,
  ) async {
    await _pumpWalkie(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Choose person'));
    await tester.pump();

    expect(find.text('No online private peers available yet.'), findsOneWidget);
  });

  testWidgets('invite action is shown for an online peer', (tester) async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    await _pumpWalkie(tester, transport: transport, foreground: foreground);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );
    await container.read(chatControllerProvider.notifier).startMesh();
    transport.connectPeer('endpoint-1', name: 'Alex', nodeId: 'peer-1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Choose person'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Invite'), findsWidgets);
  });

  testWidgets('private stay online shows and toggles always-on state', (
    tester,
  ) async {
    final contactStore = InMemoryKnownContactStore();
    await _pumpWalkie(tester, knownContactStore: contactStore);

    await contactStore.upsert(
      KnownContact(
        nodeId: 'peer-1',
        displayName: 'Alex',
        publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        lastSeenAt: DateTime(2026),
      ),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WalkieScreen)),
    );
    container
        .read(chatControllerProvider.notifier)
        .selectConversation(
          const PrivateConversation(peerNodeId: 'peer-1', peerName: 'Alex'),
        );
    await tester.pumpAndSettle();

    final stayOnlineButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Offline'),
    );
    expect(stayOnlineButton.onPressed, isNotNull);

    var contact = contactStore.contacts.singleWhere(
      (item) => item.nodeId == 'peer-1',
    );
    expect(contact.isTrusted, isFalse);
    expect(contact.walkieAlwaysOn, isFalse);

    await container
        .read(chatControllerProvider.notifier)
        .trustContact('peer-1');
    await tester.pumpAndSettle();

    final enabledButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Offline'),
    );
    expect(enabledButton.onPressed, isNotNull);

    // Simulate the app missing a contact stream refresh before the user taps.
    // The button should still flip because the controller refreshes its state
    // directly after writing the private walkie setting.
    await contactStore.setWalkieAlwaysOn('peer-1', false);
    await tester.tap(find.widgetWithText(FilledButton, 'Offline'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Online'), findsOneWidget);
    contact = contactStore.contacts.singleWhere(
      (item) => item.nodeId == 'peer-1',
    );
    expect(contact.isTrusted, isTrue);
    expect(contact.walkieAlwaysOn, isTrue);
  });
}
