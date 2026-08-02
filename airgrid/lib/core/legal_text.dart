class LegalText {
  LegalText._();

  static const termsVersion = '2026-06-07';
  static const termsUrl = 'https://airgridmessenger.netlify.app/#terms-of-use';
  static const privacyUrl =
      'https://airgridmessenger.netlify.app/#privacy-policy';
  static const supportEmail = 'jayarous@gmail.com';

  static const acknowledgement =
      'I agree to the Terms of Use and acknowledge AirGrid\'s safety limits.';

  static const shortSafetyNotice =
      'AirGrid is not an emergency or life-safety service. Nearby discovery, '
      'message delivery, encryption, relays, walkie audio, and location sharing '
      'can fail or be inaccurate.';

  static const sections = <LegalSection>[
    LegalSection(
      'Terms of Use',
      'By using AirGrid, you agree to these terms. AirGrid is provided as is, '
          'without warranties, and your use of the app is at your own risk. These '
          'terms should be reviewed by qualified legal counsel before public release.',
    ),
    LegalSection(
      'Not for emergencies',
      'Do not rely on AirGrid for emergency, life-safety, rescue, medical, '
          'military, aviation, disaster-response, or other critical communications. '
          'Use official emergency channels and appropriate professional systems.',
    ),
    LegalSection(
      'Mesh limits',
      'AirGrid depends on nearby devices, Google Play Services, Bluetooth, '
          'Wi-Fi Direct, Android permissions, battery settings, radio conditions, '
          'and distance. Discovery, message delivery, relays, store-and-forward, '
          'walkie audio, and location sharing may fail, be delayed, or be inaccurate.',
    ),
    LegalSection(
      'Privacy and encryption limits',
      'Public nearby chat and routing metadata may be visible to nearby AirGrid '
          'devices. Private encryption is opportunistic and does not provide a full '
          'verified identity system. Location sharing is optional and should be used '
          'only with people you trust.',
    ),
    LegalSection(
      'User responsibility',
      'You are responsible for your messages, media, location sharing, conduct, '
          'and compliance with laws that apply to you. Do not use AirGrid to send '
          'illegal, harmful, threatening, abusive, harassing, sexually exploitative, '
          'hateful, impersonating, spam, or otherwise objectionable content.',
    ),
    LegalSection(
      'Age requirement',
      'You must be at least 13 years old to use AirGrid. If you are between 13 '
          'and 17, you may use AirGrid only with permission from a parent or guardian.',
    ),
    LegalSection(
      'Blocking and reports',
      'AirGrid includes local blocking and safety reporting tools. Reports are '
          'stored on your device unless you choose to export or send them. AirGrid '
          'does not operate a central moderation server for normal mesh messaging.',
    ),
    LegalSection(
      'Liability',
      'To the maximum extent permitted by law, the AirGrid maintainers are not '
          'liable for losses, damages, missed messages, inaccurate location, user '
          'content, third-party conduct, or reliance on the app for critical needs.',
    ),
    LegalSection(
      'Contact',
      'Questions about these terms, privacy, or safety can be sent to '
          '$supportEmail.',
    ),
  ];
}

class LegalSection {
  final String title;
  final String body;

  const LegalSection(this.title, this.body);
}
