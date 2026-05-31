import 'package:airgrid/app/airgrid_app.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/data/storage/sqlite_message_repository.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final identityStore = await LocalIdentityStore.create();
  final messageRepo = await SqliteMessageRepository.open();
  final contactStore = await SharedPrefsKnownContactStore.create();
  final reportStore = await SharedPrefsLocalReportStore.create();
  final privacyStore = await SharedPrefsPrivacySettingsStore.create();
  final publicWalkieStore = await SharedPrefsPublicWalkieSettingsStore.create();
  final batteryStore = await SharedPrefsBatterySettingsStore.create();
  final chatListPreferencesStore =
      await SharedPrefsChatListPreferencesStore.create();

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
        batterySettingsStoreProvider.overrideWithValue(batteryStore),
        chatListPreferencesStoreProvider.overrideWithValue(
          chatListPreferencesStore,
        ),
      ],
      child: AirGridApp(identityStore: identityStore),
    ),
  );
}
