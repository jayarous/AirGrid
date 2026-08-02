/// Walkie-talkie session state, split out of `ChatState`.
///
/// These nine fields are a self-contained state machine — target selection,
/// invite handshake, transmit/send flags — that happens to be driven by the
/// same controller as chat. Grouping them keeps `ChatState` legible and lets
/// widgets watch `select((s) => s.walkie)` instead of rebuilding on every
/// unrelated chat change.
class WalkieState {
  /// Node ID currently selected for walkie-talkie quick actions.
  final String? peerNodeId;

  /// True while the user is actively holding the transmit button.
  final bool isTransmitting;

  /// True while a captured clip is being sent.
  final bool isSending;

  /// Last walkie-specific error shown to the user.
  final String? lastError;

  /// Whether public walkie audio keeps playing after leaving the screen.
  final bool publicStayOnline;

  /// Session id for the current invite or active handshake.
  final String? inviteSessionId;

  /// Peer node id for the current invite or active handshake.
  final String? invitePeerNodeId;

  /// True when the current invite was received rather than sent.
  final bool inviteIsIncoming;

  /// Peer node id of the active session, once accepted.
  final String? sessionActivePeerNodeId;

  const WalkieState({
    this.peerNodeId,
    this.isTransmitting = false,
    this.isSending = false,
    this.lastError,
    this.publicStayOnline = false,
    this.inviteSessionId,
    this.invitePeerNodeId,
    this.inviteIsIncoming = false,
    this.sessionActivePeerNodeId,
  });

  const WalkieState.initial()
    : peerNodeId = null,
      isTransmitting = false,
      isSending = false,
      lastError = null,
      publicStayOnline = false,
      inviteSessionId = null,
      invitePeerNodeId = null,
      inviteIsIncoming = false,
      sessionActivePeerNodeId = null;

  /// True when an invite is outstanding in either direction.
  bool get hasPendingInvite => inviteSessionId != null;

  /// True when a session has been accepted and is live.
  bool get hasActiveSession => sessionActivePeerNodeId != null;

  WalkieState copyWith({
    String? peerNodeId,
    bool? isTransmitting,
    bool? isSending,
    String? lastError,
    bool? publicStayOnline,
    String? inviteSessionId,
    String? invitePeerNodeId,
    bool? inviteIsIncoming,
    String? sessionActivePeerNodeId,
    bool clearPeerNodeId = false,
    bool clearLastError = false,
    bool clearInvite = false,
    bool clearSessionActivePeerNodeId = false,
  }) {
    return WalkieState(
      peerNodeId: clearPeerNodeId ? null : peerNodeId ?? this.peerNodeId,
      isTransmitting: isTransmitting ?? this.isTransmitting,
      isSending: isSending ?? this.isSending,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      publicStayOnline: publicStayOnline ?? this.publicStayOnline,
      inviteSessionId: clearInvite
          ? null
          : inviteSessionId ?? this.inviteSessionId,
      invitePeerNodeId: clearInvite
          ? null
          : invitePeerNodeId ?? this.invitePeerNodeId,
      inviteIsIncoming: clearInvite
          ? false
          : inviteIsIncoming ?? this.inviteIsIncoming,
      sessionActivePeerNodeId: clearSessionActivePeerNodeId
          ? null
          : sessionActivePeerNodeId ?? this.sessionActivePeerNodeId,
    );
  }
}
