/// Controls which peers this device interacts with on the mesh.
enum PrivacyMode {
  /// Default — accept messages and show location for all discovered peers.
  everyoneNearby,

  /// Restrict interaction to explicitly trusted contacts only.
  trustedContactsOnly;

  String get label {
    switch (this) {
      case PrivacyMode.everyoneNearby:
        return 'Everyone nearby';
      case PrivacyMode.trustedContactsOnly:
        return 'Invited friends only';
    }
  }

  String get description {
    switch (this) {
      case PrivacyMode.everyoneNearby:
        return 'Receive messages and location from all nearby users.';
      case PrivacyMode.trustedContactsOnly:
        return 'Only receive messages and location from invited friends.';
    }
  }
}
