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

Release builds use `android/key.properties`, which points to the local upload
keystore outside the Flutter project:

```text
C:/Users/jayar/Desktop/AirGrid/release-signing/airgrid-upload.jks
```

Do not commit `android/key.properties` or the keystore. Back up both securely.
If either is lost, future Play uploads may require upload-key reset through
Google Play Console.

Upload key SHA-256:

```text
18:D4:FB:DA:F2:B3:3C:B8:42:FD:38:5D:0F:8E:0D:4B:C9:05:53:34:A9:06:56:4E:BF:B0:58:18:6A:95:90:69
```

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
