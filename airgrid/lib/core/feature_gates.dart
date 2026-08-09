import 'package:airgrid/domain/models/entitlement.dart';

/// Pure, synchronous answers to "may this device do X?".
///
/// Two rules govern everything in this file.
///
/// **Every gate is sender-side.** Nothing here may be consulted on a receive
/// path, in a relay decision, or anywhere that changes what goes on the wire.
/// Free devices are mesh infrastructure for paying users: a gate that reaches
/// the wire degrades the product for the people who paid for it.
///
/// **Sessions are gated at the start, never at the join.** Private walkie and
/// Rider Mode are two-sided. If a free user cannot accept, a paying user's
/// headline feature only works when the person they are talking to has also
/// paid — so the payer hits a wall and blames the app, not the paywall. A free
/// peer accepting and talking back for the full session is also the best
/// conversion funnel available: a live demo, with a real person, in their hand.
///
/// The `=> true` getters are therefore not dead code. They are the invariants,
/// written where the gates live, so that weakening one means deleting a
/// documented promise rather than quietly adding a condition.
class FeatureGates {
  final Entitlement entitlement;
  final DateTime Function() _clock;

  FeatureGates(this.entitlement, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Free-tier gates, for tests and for a device with no cached entitlement.
  factory FeatureGates.free({DateTime Function()? clock}) =>
      FeatureGates(Entitlement.free, clock: clock);

  EntitlementStatus get status => entitlement.statusAt(_clock());

  bool get isPlus => entitlement.isPlusAt(_clock());

  // ── Private walkie ───────────────────────────────────────────────────────

  /// Starting a private walkie session. The headline paid feature.
  bool get canStartWalkieSession => isPlus;

  /// Accepting an invite is always free. See the class doc — this is
  /// load-bearing for the paid experience, not a concession.
  bool get canAcceptWalkieSession => true;

  /// Declining is always free; a user must be able to refuse.
  bool get canDeclineWalkieSession => true;

  /// Ending a session is always free. Trapping a free user inside a session
  /// they cannot leave would be indefensible.
  bool get canEndWalkieSession => true;

  /// Transmitting a private walkie clip.
  ///
  /// **Free inside an active session, Plus outside one.** This is where the
  /// accept-side rule is actually enforced: a free peer who accepted an invite
  /// must be able to talk back for the full session, or the paying user's
  /// feature is broken. But with no session established, transmitting *is*
  /// starting a conversation, and the invite gate would otherwise be trivially
  /// bypassed by selecting a target and pressing the button.
  ///
  /// Voice notes are not walkie clips and are never gated — see
  /// [canSendVoiceNote].
  bool canTransmitPrivateWalkie({required bool inActiveSession}) =>
      inActiveSession || isPlus;

  // ── Public walkie ────────────────────────────────────────────────────────

  /// Broadcasting to the whole mesh. Gating this also helps mesh health: an
  /// 8-hop flood of a 96 KiB clip is the heaviest traffic AirGrid carries, and
  /// the inbound limiter counts packets rather than bytes, so it does not
  /// throttle media proportionally.
  bool get canEnablePublicWalkie => isPlus;

  /// Transmitting a public walkie clip.
  ///
  /// Always Plus, with no session exemption: public walkie has no invitation and
  /// no counterparty, so every transmit is one this device started, and it
  /// reaches the whole mesh. Gating only the stay-online toggle would leave the
  /// broadcast itself wide open.
  bool get canBroadcastPublicWalkie => isPlus;

  /// Receiving and relaying public walkie audio is always free. If free
  /// devices stopped relaying `audio`, public walkie would break for exactly
  /// the users paying for it.
  bool get canRelayWalkieAudio => true;

  // ── Rider Mode ───────────────────────────────────────────────────────────

  /// Starting a rider session.
  bool get canStartRiderSession => isPlus;

  /// Arming rider presence is always free, for two reasons. It is how peers
  /// *discover* that someone is available to ride, so gating it would make free
  /// users invisible to paying riders. And it is published inside a
  /// `key_announce` packet, so gating it would change the wire.
  bool get canArmRiderPresence => true;

  /// Accepting an incoming rider session, including the trusted auto-join
  /// path, is always free.
  bool get canAcceptRiderSession => true;

  // ── Attachments ──────────────────────────────────────────────────────────

  /// Arbitrary file attachments are paid.
  ///
  /// This gates the attachment *type*, never its size. Size caps are derived
  /// from `kMaxPacketBytes` and are part of the wire contract: raising one for
  /// paid users would require receivers to accept a larger envelope, which is a
  /// wire-format change needing a staged rollout, not a flag flip.
  bool get canSendFileAttachment => isPlus;

  /// Images are free.
  bool get canSendImage => true;

  /// Voice notes are free. A voice note is a chat message, and chat is free.
  bool get canSendVoiceNote => true;

  // ── History ──────────────────────────────────────────────────────────────

  /// Exporting local history is paid. Purely local; no wire impact.
  bool get canExportHistory => isPlus;
}
