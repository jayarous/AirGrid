import 'package:airgrid/app/airgrid_app.dart';
import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/legal_text.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/onboarding/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _EmptyMessageRepository implements MessageRepository {
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

Future<LocalIdentityStore> _identity(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

Future<void> _pumpOnboarding(
  WidgetTester tester,
  LocalIdentityStore identity,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [localIdentityStoreProvider.overrideWithValue(identity)],
      child: MaterialApp(
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: const OnboardingScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('onboarding requires terms acceptance before continuing', (
    tester,
  ) async {
    final identity = await _identity({});
    await _pumpOnboarding(tester, identity);

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Jay');
    await tester.pump();

    final continueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(continueButton.onPressed, isNull);
    expect(identity.hasAcceptedTerms(LegalText.termsVersion), isFalse);
  });

  testWidgets('onboarding persists terms acceptance after successful setup', (
    tester,
  ) async {
    final identity = await _identity({});
    await _pumpOnboarding(tester, identity);

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Jay');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(identity.displayName, 'Jay');
    expect(identity.hasAcceptedTerms(LegalText.termsVersion), isTrue);
  });

  testWidgets('existing users must accept current terms version', (
    tester,
  ) async {
    final identity = await _identity({
      'airgrid_node_id': 'local-node',
      'airgrid_display_name': 'Jay',
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localIdentityStoreProvider.overrideWithValue(identity),
          messageRepositoryProvider.overrideWithValue(
            _EmptyMessageRepository(),
          ),
          transportServiceProvider.overrideWithValue(FakeTransport()),
          playServicesProvider.overrideWithValue(
            FakePlayServices(
              const PlayServicesStatus(
                available: true,
                code: 'available',
                message: 'Google Play Services available.',
                canResolve: false,
              ),
            ),
          ),
          foregroundServiceProvider.overrideWithValue(FakeForegroundService()),
          cryptoServiceProvider.overrideWithValue(CryptoService()),
          knownContactStoreProvider.overrideWithValue(
            InMemoryKnownContactStore(),
          ),
          localReportStoreProvider.overrideWithValue(
            InMemoryLocalReportStore(),
          ),
          privacySettingsStoreProvider.overrideWithValue(
            InMemoryPrivacySettingsStore(),
          ),
          batterySettingsStoreProvider.overrideWithValue(
            InMemoryBatterySettingsStore(),
          ),
        ],
        child: AirGridApp(identityStore: identity),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Terms & Safety'), findsOneWidget);
    expect(find.text('Accept and continue'), findsOneWidget);

    final acceptButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Accept and continue'),
    );
    expect(acceptButton.onPressed, isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Accept and continue'));
    await tester.pump();

    expect(identity.hasAcceptedTerms(LegalText.termsVersion), isTrue);
  });
}
