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
- Foreground service type `microphone` keeps Rider Mode live audio capture
  running while the user has explicitly started a one-to-one rider session.
- Foreground service type `mediaPlayback` keeps Rider Mode peer audio playback
  audible during an active user-started rider session.

Foreground service Play Console selections:

- Connected device: select `Continuous data transfer to an external device`.
- Media playback: select `Media playback`.
- Microphone: select `Background audio input`.

Foreground service declaration text:

```text
AirGrid uses a connected-device foreground service while the user has an active
nearby mesh session. The service keeps Bluetooth/Wi-Fi Direct peer discovery
and device-to-device message transfer active, shows an ongoing notification,
and can be stopped by the user from the app. If interrupted, nearby peers may
disconnect and messages may not be delivered until the mesh is restarted.

AirGrid uses a microphone foreground service only when the user explicitly
starts Rider Mode, a live one-to-one audio session with a trusted nearby peer.
The service captures microphone audio for the active rider session, shows an
ongoing notification with mute/end actions, and stops when the user ends Rider
Mode.

AirGrid uses a media playback foreground service only during active Rider Mode
sessions so incoming peer audio can continue playing while the user leaves the
app. Playback is tied to the user-started rider session, shows an ongoing
notification, and stops when the user ends Rider Mode.
```

## Store Listing Draft

Short description:

```text
Offline nearby mesh chat for Android devices without internet or mobile data.
```

Full description draft:

```text
AirGrid is an offline-first nearby chat app for Android. It lets nearby devices
exchange messages directly using Bluetooth and Wi-Fi Direct through Google
Nearby Connections, without internet, mobile data, routers, or a central
messaging server.

Use AirGrid when people are close by but normal connectivity is limited,
unavailable, or unnecessary. Nearby users can discover each other, join a local
mesh, and send public or private messages between connected Android devices.

Key features:

Offline nearby messaging
Chat with nearby Android devices without relying on internet access or mobile
data.

Local mesh communication
Messages can move between connected nearby devices using a local peer-to-peer
mesh.

Public nearby chat
Send messages to people around you who are connected to the same local AirGrid
mesh.

Private chat
Message selected nearby contacts directly when they are available in the mesh.

Encrypted private messaging
AirGrid supports opportunistic encryption for private messages after devices
exchange the required public keys.

Voice notes and media sharing
Send voice notes, photos, and files to nearby peers when the local mesh
connection supports the transfer.

Walkie-talkie audio
Send short public walkie clips to the local mesh or start an invited private
walkie session with a selected peer.

Rider Mode
Start a trusted one-to-one live audio session with mute controls and
voice-activated microphone support for close-range coordination.

Local message history
Messages are stored on your device and not on a central AirGrid server, so you
can view recent conversations locally.

Known and trusted contacts
AirGrid can remember nearby contacts discovered through the mesh. You can mark
trusted contacts for private walkie and Rider Mode features.

Optional location sharing
Share your location with connected peers only when you choose to use that
feature.

AirGrid is designed for local communication. It does not operate a central
messaging server for normal mesh messaging, and your messages are exchanged
directly with nearby devices.

Google Play Services is required. AirGrid also needs nearby device permissions
such as Bluetooth, Wi-Fi, notifications, microphone, and location-related
permissions because Android requires them for nearby discovery,
device-to-device connections, foreground mesh sessions, and optional audio or
location features.

Mesh performance may vary depending on device hardware, Android version,
distance, radio conditions, and the number of nearby peers.

AirGrid can be useful during events, travel, outdoor activities such as hiking
and camping, campuses, workplaces, community gatherings, dormitories, hostels,
hotels, and emergency preparedness situations where nearby people need to
communicate without relying on internet or mobile data.

Keep AirGrid ready on your device. You never know when nearby offline
communication will be useful.

AirGrid is currently Android-only.
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
