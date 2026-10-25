# AirGrid R8 keep rules.
#
# Release builds run R8 with code minification and resource shrinking (the
# Flutter defaults) plus android.r8.optimizedShrinking (gradle.properties).
# Nearly every rule the app needs arrives bundled inside the AARs it depends
# on and is merged automatically; the merged result of each release build is
# written to build/app/outputs/mapping/release/configuration.txt, and
# tool/check_r8_release.ps1 checks it after every release build.
#
# This file pins only the rules whose loss would not fail the build or crash
# the app, but corrupt it quietly. Keep it narrow: a blanket keep on a
# library undoes the shrinking and hides real problems behind it.

# ── Flutter plugin entry point ─────────────────────────────────────────────
# FlutterEngine finds the generated registrant with Class.forName and invokes
# registerWith reflectively. R8 resolves the constant-string lookup on its
# own today; if that ever regressed, every plugin would be absent at runtime
# with no build error. Pinning it costs one class.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# ── Secure storage: flutter_secure_storage → androidx.security-crypto → Tink ─
# Both secure stores (LocalIdentityStore, EntitlementStore) open
# EncryptedSharedPreferences with resetOnError: true. If Tink cannot read a
# keyset, the plugin does not throw; it wipes the store and starts over. On a
# paying user that is a silent downgrade, and on any user it is a new node
# identity, which every contact then sees as a key change.
#
# Tink parses keysets with a shaded protobuf-lite that reads message fields by
# reflection. This exact rule ships inside tink-android
# (META-INF/proguard/protobuf.pro) and is pinned here so that a Tink or
# security-crypto upgrade that stopped shipping it could not take the
# protection away unnoticed.
-keepclassmembers class * extends com.google.crypto.tink.shaded.protobuf.GeneratedMessageLite {
  <fields>;
}
# The classes EncryptedSharedPreferences uses to build and unwrap the master
# key. They are reached statically today: AndroidKeysetManager survived the
# 1.0.14 build as a class, and the two key managers had been inlined into
# their callers, which is correct as long as nothing resolves them by name.
# The keep makes them a stable, checkable presence in mapping.txt and guards
# against a future version of the stack looking them up by name.
-keep class com.google.crypto.tink.integration.android.AndroidKeysetManager { *; }
-keep class com.google.crypto.tink.aead.AesGcmKeyManager { *; }
-keep class com.google.crypto.tink.daead.AesSivKeyManager { *; }

# ── Deliberately no rules ──────────────────────────────────────────────────
# nearby_connections / play-services-nearby: the plugin calls the GMS client
#   API directly; GMS SafeParcelable and Nearby rules come from the
#   play-services-basement and play-services-nearby AARs.
# in_app_purchase_android / Play Billing: Pigeon-generated messages, no
#   reflection; billing-8.0.0 ships its own ProxyBillingActivity keepnames.
# sqflite, record, geolocator, permission_handler: plain Java/Kotlin plugin
#   code with no reflection or serialisation; their FlutterPlugin classes are
#   covered by Flutter's own -if/-keep rule (flutter_proguard_rules.pro).
# Our own MainActivity and NearbyForegroundService are manifest components
#   and kept by the manifest-derived rules.
