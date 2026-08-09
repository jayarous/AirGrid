import 'dart:async';

import 'package:airgrid/app/airgrid_app.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/billing/play_billing_service.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/data/storage/rider_mode_settings_store.dart';
import 'package:airgrid/data/storage/sqlite_message_repository.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final identityStore = await LocalIdentityStore.create();
  final messageRepo = await SqliteMessageRepository.open();
  final contactStore = await SharedPrefsKnownContactStore.create();
  final reportStore = await SharedPrefsLocalReportStore.create();
  final privacyStore = await SharedPrefsPrivacySettingsStore.create();
  final publicWalkieStore = await SharedPrefsPublicWalkieSettingsStore.create();
  final riderModeSettingsStore =
      await SharedPrefsRiderModeSettingsStore.create();
  final batteryStore = await SharedPrefsBatterySettingsStore.create();
  final chatListPreferencesStore =
      await SharedPrefsChatListPreferencesStore.create();
  final entitlementStore = await SecureEntitlementStore.create();
  final billingService = PlayBillingService()..start();

  // A device that has never accepted the terms has never run an earlier build,
  // so it has no idea live voice was ever free and there is nothing to explain.
  // Marking the notice seen here retires it before it can reach a first-time
  // user, who would otherwise be told a feature they have never opened "is now"
  // paid. Done before runApp so it settles ahead of the terms dialog.
  if (identityStore.acceptedTermsVersion == null) {
    await entitlementStore.markChangeNoticeShown(
      SubscriptionCatalog.plusNoticeVersion,
    );
  }

  final cryptoService = CryptoService();
  await cryptoService.loadLocalKeyPair(
    identityStore.privateKeyBase64!,
    identityStore.publicKeyBase64!,
  );

  runApp(
    ProviderScope(
      overrides: [
        localIdentityStoreProvider.overrideWithValue(identityStore),
        messageRepositoryProvider.overrideWithValue(messageRepo),
        cryptoServiceProvider.overrideWithValue(cryptoService),
        knownContactStoreProvider.overrideWithValue(contactStore),
        localReportStoreProvider.overrideWithValue(reportStore),
        privacySettingsStoreProvider.overrideWithValue(privacyStore),
        publicWalkieSettingsStoreProvider.overrideWithValue(publicWalkieStore),
        riderModeSettingsStoreProvider.overrideWithValue(
          riderModeSettingsStore,
        ),
        batterySettingsStoreProvider.overrideWithValue(batteryStore),
        chatListPreferencesStoreProvider.overrideWithValue(
          chatListPreferencesStore,
        ),
        entitlementStoreProvider.overrideWithValue(entitlementStore),
        billingServiceProvider.overrideWithValue(billingService),
      ],
      child: AirGridApp(identityStore: identityStore),
    ),
  );

  // Deliberately after runApp and never awaited. AirGrid has to start and run
  // with Play entirely unreachable, so billing must not sit on the path to the
  // first frame — and a failed query leaves the cached entitlement alone.
  unawaited(_syncEntitlement(billingService, entitlementStore));
}

/// Keeps the cached entitlement in step with Play, in the background.
///
/// Both paths funnel through [EntitlementStore.reconcile], which is where the
/// rule that a null result means "unknown" rather than "not subscribed" lives.
Future<void> _syncEntitlement(
  BillingService billing,
  EntitlementStore store,
) async {
  // Renewals, cancellations and purchases that settle late.
  billing.entitlementUpdates.listen((entitlement) {
    unawaited(store.reconcile(entitlement));
  });

  await store.reconcile(await billing.queryEntitlement());
}
