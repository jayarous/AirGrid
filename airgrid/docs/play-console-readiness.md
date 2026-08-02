# AirGrid Play Console Readiness

This checklist is for the first Google Play upload on the Internal testing
track.

## App Identity

- App name: AirGrid
- Package name / application ID: `com.airgrid.app`
- Category: Communication
- First track: Internal testing
- Artifact type: Android App Bundle (`.aab`)

The package name is permanent once the app is published. Use
`com.airgrid.app` for this Play listing only.

## Release Signing

Release builds use `android/key.properties`, which points to an upload keystore
stored **outside the repository**. Keep the keystore in a private location such
as `~/.android-keys/` (or the Windows equivalent) and point `storeFile` at it.

Never commit `android/key.properties`, the keystore, or the upload key
fingerprint. The repository root `.gitignore` blocks `*.jks`, `*.keystore`,
`key.properties`, and `release-signing/`; do not weaken those rules.

Back up the keystore and its passwords securely and separately. If either is
lost, future Play uploads require an upload-key reset through Google Play
Console.

To read the upload key fingerprint locally when Play Console asks for it:

```bash
keytool -list -v -keystore <path-to-keystore> -alias <alias>
```

Do not paste the output into this file or any other tracked document.

## Build And Checks

Run before upload:

```bash
./build_release_aab.ps1
```

This script increments patch/build version in `pubspec.yaml`, then builds the
release AAB so the in-app version label matches the uploaded artifact.

Upload this artifact to Internal testing:

```text
build/app/outputs/bundle/release/app-release.aab
```

## Play Console App Content

Privacy policy URL:

```text
https://airgridmessenger.netlify.app
```

Data Safety should disclose:

- Display name used for nearby chat identity.
- Message content stored locally on the device.
- Device-generated node ID used for mesh routing.
- Nearby/Bluetooth/Wi-Fi discovery for local peer connections.
- Location data if the user enables location sharing.
- Users can limit interactions to Invited Friends only from Settings >
  Nearby Visibility.
- No central AirGrid server collection for normal mesh messaging.

Permissions declaration notes:

- Bluetooth and Nearby Wi-Fi are required for Nearby Connections peer discovery
  and device-to-device transfer.
- Location is requested because Nearby Connections may require it on Android
  versions and because AirGrid includes user-visible location sharing.
- Notifications are used for foreground mesh session visibility.
- Foreground service type `connectedDevice` keeps an active user-started mesh
  session running while peers discover and exchange messages.
- Foreground service type `location` is contributed by the location plugin and
  supports user-visible location sharing while the app has foreground location
  permission.

Foreground service declaration text:

```text
AirGrid uses a connected-device foreground service while the user has an active
nearby mesh session. The service keeps Bluetooth/Wi-Fi Direct peer discovery
and device-to-device message transfer active, shows an ongoing notification,
and can be stopped by the user from the app. If interrupted, nearby peers may
disconnect and messages may not be delivered until the mesh is restarted.

AirGrid also includes a location foreground-service type for optional
user-visible location sharing with connected peers. Location access is requested
with foreground permission and is used only for app features disclosed to the
user.
```

## Store Listing Draft

Short description:

```text
Offline nearby mesh chat for Android devices without internet or mobile data.
```

Full description draft:

```text
AirGrid is an offline-first nearby chat app for Android. It lets nearby devices
exchange public and private messages over Google Nearby Connections using
Bluetooth and Wi-Fi Direct, without internet, mobile data, routers, or a central
server.

AirGrid supports local mesh discovery, public nearby chat, private chat,
opportunistic encrypted private messaging, local message history, known
contacts, and optional location sharing between connected peers.

Google Play Services and nearby device permissions are required for the mesh
transport to work. Real mesh behavior depends on device hardware, Android
version, radio conditions, and distance between devices.
```

## Device Validation Before Wider Release

Test on at least two physical Android devices with Google Play Services:

- onboarding
- permission prompts
- peer discovery
- foreground notification
- public messages
- private messages
- encrypted private messages after key exchange
- optional location sharing
- background/foreground transitions
- uninstall/reinstall identity reset behavior
