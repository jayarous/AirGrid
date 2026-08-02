/// How healthy an active Rider Mode link looks, judged purely on how long the
/// peer has been silent.
enum RiderLinkHealth {
  /// Heard from recently.
  healthy,

  /// Overdue, but still worth waiting on. Warn, do not tear down.
  stale,

  /// Long enough gone to treat the session as over.
  lost,
}

/// Missed keepalives before the link is flagged as unstable.
const riderPeerStaleAfter = Duration(seconds: 6);

/// Missed keepalives before the session is torn down. This is the backstop for
/// the cases where nothing arrives on the wire at all - app killed, battery
/// flat, or ridden out of range - so no explicit `end` is ever sent.
const riderPeerLostAfter = Duration(seconds: 15);

/// Classifies a silence gap. Pure, so the thresholds can be tested directly.
RiderLinkHealth riderLinkHealthFor(Duration silence) {
  if (silence >= riderPeerLostAfter) return RiderLinkHealth.lost;
  if (silence >= riderPeerStaleAfter) return RiderLinkHealth.stale;
  return RiderLinkHealth.healthy;
}
