# AirGrid Privacy Policy Draft

Last updated: May 28, 2026

AirGrid is an offline-first nearby mesh chat app for Android. AirGrid is
designed to exchange messages directly between nearby devices using Google
Nearby Connections. AirGrid does not operate a central messaging server.

## Information AirGrid Uses

AirGrid may store or process the following information on your device:

- Display name you choose during onboarding.
- Messages you send and receive.
- A randomly generated node ID used to identify your device inside the local
  mesh.
- Cryptographic key material used for encrypted private messages.
- Known contacts discovered through nearby mesh communication.
- Optional location information when you choose to share location with connected
  peers.

## How Information Is Used

AirGrid uses this information to:

- discover nearby devices
- route messages across the local mesh
- show chat history on your device
- support private and encrypted private messaging
- reconnect to known contacts
- share location with connected peers when enabled

## Storage

Messages and known contacts are stored locally on your device. Cryptographic
private keys are stored using Android secure storage through Flutter secure
storage. Display name and node ID are stored locally in app preferences.

## Sharing

AirGrid sends chat messages, public keys, routing metadata, display names, and
optional location data directly to nearby devices as part of the mesh
functionality. Because mesh messages may be relayed by nearby devices, other
AirGrid devices may temporarily handle routing metadata required to deliver
messages.

AirGrid does not sell personal data.

## Permissions

AirGrid requests permissions needed for nearby device communication and app
functionality:

- Bluetooth and Nearby Wi-Fi permissions for peer discovery and device-to-device
  transfer.
- Location permission because Nearby Connections may require it on Android
  versions and because AirGrid supports optional location sharing.
- Notification permission so the app can show an ongoing notification while a
  mesh session is active.

## Deleting Data

You can clear local chat data from inside the app where available, or remove all
AirGrid local data by uninstalling the app or clearing app storage in Android
settings.

## Contact

For privacy questions, provide your support email address here before publishing
this policy.
