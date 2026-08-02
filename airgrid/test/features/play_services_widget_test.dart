import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/chat_screen.dart';
import 'package:airgrid/features/home/home_screen.dart';
import 'package:airgrid/features/nearby/nearby_preferences.dart';
import 'package:airgrid/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _FakeMeshPermissions extends MeshPermissions {
  const _FakeMeshPermissions();

  @override
  Future<MeshPermissionsSnapshot> checkStatuses() async {
    return MeshPermissionsSnapshot({
      for (final permission in MeshPermissions.allPermissions)
        permission: PermissionStatus.granted,
    });
  }

  @override
  Future<MeshPermissionsSnapshot> requestMeshPermissions() => checkStatuses();
}

class _RecordingMessageRepository implements MessageRepository {
  int clearAllCount = 0;

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async => [];

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> clearAll() async {
    clearAllCount++;
  }
}

Finder _settingsClearTile() {
  return find.byWidgetPredicate((widget) {
    final title = widget is ListTile ? widget.title : null;
    return title is Text && title.data == 'Clear all chats';
  });
}

Future<LocalIdentityStore> _identity({Map<String, Object>? extraPrefs}) async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': 'local-node',
    'airgrid_display_name': 'Jay',
    ...?extraPrefs,
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

Future<void> _pumpWithProviders(
  WidgetTester tester,
  Widget child,
  PlayServicesStatus playServicesStatus, {
  _RecordingMessageRepository? repository,
  Map<String, Object>? extraPrefs,
  FakeTransport? transport,
  FakeForegroundService? foreground,
}) async {
  final foregroundService = foreground ?? FakeForegroundService();
  final meshTransport = transport ?? FakeTransport();
  addTearDown(foregroundService.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localIdentityStoreProvider.overrideWithValue(
          await _identity(extraPrefs: extraPrefs),
        ),
        messageRepositoryProvider.overrideWithValue(
          repository ?? _RecordingMessageRepository(),
        ),
        transportServiceProvider.overrideWithValue(meshTransport),
        playServicesProvider.overrideWithValue(
          FakePlayServices(playServicesStatus),
        ),
        foregroundServiceProvider.overrideWithValue(foregroundService),
        cryptoServiceProvider.overrideWithValue(CryptoService()),
        knownContactStoreProvider.overrideWithValue(
          InMemoryKnownContactStore(),
        ),
        localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
        privacySettingsStoreProvider.overrideWithValue(
          InMemoryPrivacySettingsStore(),
        ),
        publicWalkieSettingsStoreProvider.overrideWithValue(
          InMemoryPublicWalkieSettingsStore(),
        ),
        chatListPreferencesStoreProvider.overrideWithValue(
          InMemoryChatListPreferencesStore(),
        ),
        batterySettingsStoreProvider.overrideWithValue(
          InMemoryBatterySettingsStore(),
        ),
        meshPermissionsProvider.overrideWithValue(const _FakeMeshPermissions()),
      ],
      child: MaterialApp(
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const unavailable = PlayServicesStatus(
    available: false,
    code: 'unsupported',
    message: 'Google Play Services is not supported on this device.',
    canResolve: false,
  );

  testWidgets('Home shows blocked Nearby state when Play Services is missing', (
    tester,
  ) async {
    await _pumpWithProviders(tester, const HomeScreen(), unavailable);

    expect(find.text('Nearby is unavailable'), findsOneWidget);
    expect(find.text('Mesh Offline'), findsOneWidget);
    expect(find.text('Mesh Online'), findsNothing);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Scanning for devices'), findsNothing);
    expect(find.text('Nearby unavailable'), findsOneWidget);
  });

  testWidgets('Home mesh chips show popup messages when toggled on', (
    tester,
  ) async {
    await _pumpWithProviders(
      tester,
      const HomeScreen(),
      const PlayServicesStatus.available(),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );

    if (container.read(chatControllerProvider).isDiscovering) {
      await tester.tap(find.text('Scanning'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Scanning'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Looking for nearby AirGrid users'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    if (container.read(chatControllerProvider).isAdvertising) {
      await tester.tap(find.text('Available'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Available'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Others AirGrid users nearby can find you'),
      findsOneWidget,
    );
  });

  testWidgets('Settings separates Play Services status from permissions', (
    tester,
  ) async {
    await _pumpWithProviders(tester, const SettingsScreen(), unavailable);

    await tester.scrollUntilVisible(
      find.text('Battery & Device Access'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Battery & Device Access'), findsOneWidget);
    expect(find.text('Google Play Services'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Bluetooth scan'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Bluetooth scan'), findsOneWidget);
  });

  testWidgets('Settings shows battery optimization controls and note changes', (
    tester,
  ) async {
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
    );

    expect(find.text('AirGrid battery saver'), findsOneWidget);
    // Battery saver defaults OFF (ChatState.batteryOptimizationEnabled, set to
    // false by RiderModeReady -- rider mode needs continuous background mesh
    // activity). So the "Off:" note is what renders first, and toggling swaps
    // it to the "On:" note. This assertion pair is the point of the test: the
    // subtitle has to track the switch.
    expect(find.textContaining('may continue scanning'), findsOneWidget);
    expect(find.text('Mesh status'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Available'), findsOneWidget);
    expect(find.text('Scanning'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);

    final batterySaverSwitch = find.widgetWithText(
      SwitchListTile,
      'AirGrid battery saver',
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(batterySaverSwitch);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('stops scanning and sharing location'),
      findsOneWidget,
    );
  });

  testWidgets('Settings opens Terms & Safety screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
    );

    await tester.scrollUntilVisible(
      find.text('Terms & Safety'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final legalTile = find.byWidgetPredicate((widget) {
      final title = widget is ListTile ? widget.title : null;
      return title is Text && title.data == 'Terms & Safety';
    });
    await tester.ensureVisible(legalTile);
    await tester.tap(legalTile);
    await tester.pumpAndSettle();

    expect(find.text('Version 2026-06-07'), findsOneWidget);
    expect(find.text('Not for emergencies'), findsOneWidget);
  });

  testWidgets('Settings persists nearby heading smoothing', (tester) async {
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
      extraPrefs: {nearbySmoothingAlphaPrefKey: 0.18},
    );

    final slider = find.byType(Slider);
    expect(find.text('Heading smoothing'), findsOneWidget);
    expect(find.text('0.18'), findsOneWidget);

    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(nearbySmoothingAlphaPrefKey), greaterThan(0.18));
  });

  testWidgets('Settings clear all chats dialog cancels without clearing', (
    tester,
  ) async {
    final repository = _RecordingMessageRepository();
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
      repository: repository,
    );
    final clearTile = _settingsClearTile();

    await tester.scrollUntilVisible(
      clearTile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(clearTile);
    await tester.pumpAndSettle();

    expect(find.text('Clear all chats?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repository.clearAllCount, 0);
  });

  testWidgets('Settings clear all chats confirms and clears repository', (
    tester,
  ) async {
    final repository = _RecordingMessageRepository();
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
      repository: repository,
    );
    final clearTile = _settingsClearTile();

    await tester.scrollUntilVisible(
      clearTile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(clearTile);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(repository.clearAllCount, 1);
  });

  testWidgets('Chat overflow clear all chats dialog cancels without clearing', (
    tester,
  ) async {
    final repository = _RecordingMessageRepository();
    await _pumpWithProviders(
      tester,
      const ChatScreen(),
      const PlayServicesStatus.available(),
      repository: repository,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Clear all chats'), findsOneWidget);
    await tester.tap(find.text('Clear all chats'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all chats?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repository.clearAllCount, 0);
  });

  testWidgets('Chat overflow clear all chats confirms and clears repository', (
    tester,
  ) async {
    final repository = _RecordingMessageRepository();
    await _pumpWithProviders(
      tester,
      const ChatScreen(),
      const PlayServicesStatus.available(),
      repository: repository,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all chats'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(repository.clearAllCount, 1);
  });

  testWidgets('Chat mesh status panel does not overflow on small screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpWithProviders(
      tester,
      const ChatScreen(),
      const PlayServicesStatus.available(),
    );

    await tester.tap(find.byTooltip('Mesh status'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Mesh status'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chat mesh status chips toggle advertising and discovery', (
    tester,
  ) async {
    await _pumpWithProviders(
      tester,
      const ChatScreen(),
      const PlayServicesStatus.available(),
    );

    await tester.tap(find.byTooltip('Mesh status'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );

    final beforeAdvertising = container
        .read(chatControllerProvider)
        .isAdvertising;
    final beforeDiscovering = container
        .read(chatControllerProvider)
        .isDiscovering;

    await tester.tap(find.text('Available'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Scanning'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final afterState = container.read(chatControllerProvider);
    expect(afterState.isAdvertising, isNot(beforeAdvertising));
    expect(afterState.isDiscovering, isNot(beforeDiscovering));
  });

  testWidgets(
    'Chat mesh status panel does not overflow on compact height layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpWithProviders(
        tester,
        const ChatScreen(),
        const PlayServicesStatus.available(),
      );

      await tester.tap(find.byTooltip('Mesh status'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Mesh status'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // Guards the RadioGroup migration: RadioListTile's groupValue/onChanged were
  // deprecated, so selection now propagates through a RadioGroup ancestor
  // rather than each tile. If that wiring breaks, tapping an option silently
  // stops changing anything — which analyze cannot catch.
  testWidgets('Nearby Visibility dialog applies the selected privacy mode', (
    tester,
  ) async {
    await _pumpWithProviders(
      tester,
      const SettingsScreen(),
      const PlayServicesStatus.available(),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
    expect(
      container.read(chatControllerProvider).privacyMode,
      PrivacyMode.everyoneNearby,
    );

    await tester.scrollUntilVisible(
      find.text('Nearby Visibility'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nearby Visibility'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(PrivacyMode.trustedContactsOnly.label));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      container.read(chatControllerProvider).privacyMode,
      PrivacyMode.trustedContactsOnly,
      reason: 'selection must propagate through the RadioGroup ancestor',
    );
  });
}
