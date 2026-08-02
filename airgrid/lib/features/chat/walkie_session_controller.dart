import 'dart:async';
import 'dart:convert';

import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/walkie/walkie_state.dart';
import 'package:uuid/uuid.dart';

const _walkieControlKind = 'walkie_control';
const _walkieControlActionInvite = 'invite';
const _walkieControlActionAccept = 'accept';
const _walkieControlActionDecline = 'decline';
const _walkieControlActionCancel = 'cancel';
const _walkieControlActionEnd = 'end';

class WalkieControlMessage {
  final String action;
  final String sessionId;

  const WalkieControlMessage({required this.action, required this.sessionId});

  String toWire() => jsonEncode({
    'kind': _walkieControlKind,
    'action': action,
    'sessionId': sessionId,
  });

  static WalkieControlMessage? fromContent(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != _walkieControlKind) return null;
      final action = decoded['action'] as String?;
      final sessionId = decoded['sessionId'] as String?;
      if (action == null || sessionId == null || sessionId.isEmpty) {
        return null;
      }
      return WalkieControlMessage(action: action, sessionId: sessionId);
    } catch (_) {
      return null;
    }
  }
}

typedef WalkieSendPrivateMessage =
    Future<PrivateSendResult> Function(
      MeshPeer peer,
      String content, {
      bool allowPlaintextFallback,
    });

class WalkieSessionController {
  WalkieSessionController({
    required ChatState Function() readState,
    required void Function(ChatState newState) writeState,
    required WalkieSendPrivateMessage sendPrivateMessage,
    required bool Function(String nodeId) isTrustedNode,
    required bool Function(String nodeId) isWalkieAlwaysOn,
  }) : _readState = readState,
       _writeState = writeState,
       _sendPrivateMessage = sendPrivateMessage,
       _isTrustedNode = isTrustedNode,
       _isWalkieAlwaysOn = isWalkieAlwaysOn;

  final ChatState Function() _readState;
  final void Function(ChatState newState) _writeState;
  final WalkieSendPrivateMessage _sendPrivateMessage;
  final bool Function(String nodeId) _isTrustedNode;
  final bool Function(String nodeId) _isWalkieAlwaysOn;

  /// Applies [update] to the walkie slice of the current state.
  ///
  /// Every write in this controller touches only [WalkieState], so routing them
  /// through one helper keeps the nested `copyWith` out of each call site.
  void _updateWalkie(WalkieState Function(WalkieState walkie) update) {
    final state = _readState();
    _writeState(state.copyWith(walkie: update(state.walkie)));
  }

  Future<bool> sendInvite(MeshPeer peer) async {
    final nodeId = peer.nodeId;
    if (nodeId == null) return false;

    final sessionId = const Uuid().v4();
    _updateWalkie(
      (w) => w.copyWith(
        inviteSessionId: sessionId,
        invitePeerNodeId: nodeId,
        inviteIsIncoming: false,
        peerNodeId: nodeId,
        clearLastError: true,
      ),
    );

    final result = await _sendPrivateMessage(
      peer,
      WalkieControlMessage(
        action: _walkieControlActionInvite,
        sessionId: sessionId,
      ).toWire(),
      allowPlaintextFallback: true,
    );

    if (result == PrivateSendResult.sentEncrypted ||
        result == PrivateSendResult.sentPlaintext) {
      return true;
    }

    _updateWalkie(
      (w) => w.copyWith(
        lastError: 'Failed to send invite',
        clearInvite: true,
        clearSessionActivePeerNodeId: true,
      ),
    );
    return false;
  }

  Future<bool> acceptInvite() async {
    final state = _readState();
    final invitePeerId = state.walkie.invitePeerNodeId;
    final sessionId = state.walkie.inviteSessionId;
    if (invitePeerId == null || sessionId == null) return false;

    final peer = _findPeer(invitePeerId);
    if (peer == null) return false;

    final result = await _sendPrivateMessage(
      peer,
      WalkieControlMessage(
        action: _walkieControlActionAccept,
        sessionId: sessionId,
      ).toWire(),
      allowPlaintextFallback: true,
    );

    if (result != PrivateSendResult.sentEncrypted &&
        result != PrivateSendResult.sentPlaintext) {
      _updateWalkie((w) => w.copyWith(lastError: 'Failed to accept invite'));
      return false;
    }

    _updateWalkie(
      (w) => w.copyWith(
        sessionActivePeerNodeId: invitePeerId,
        peerNodeId: invitePeerId,
        clearInvite: true,
        clearLastError: true,
      ),
    );
    return true;
  }

  Future<bool> declineInvite() async {
    final state = _readState();
    final invitePeerId = state.walkie.invitePeerNodeId;
    final sessionId = state.walkie.inviteSessionId;
    if (invitePeerId == null || sessionId == null) {
      return false;
    }

    final peer = _findPeer(invitePeerId);
    if (peer == null) {
      _updateWalkie((w) => w.copyWith(clearInvite: true));
      return false;
    }

    await _sendPrivateMessage(
      peer,
      WalkieControlMessage(
        action: _walkieControlActionDecline,
        sessionId: sessionId,
      ).toWire(),
      allowPlaintextFallback: true,
    );

    _updateWalkie((w) => w.copyWith(clearInvite: true, clearLastError: true));
    return true;
  }

  Future<bool> cancelInvite() async {
    final state = _readState();
    final invitePeerId = state.walkie.invitePeerNodeId;
    final sessionId = state.walkie.inviteSessionId;
    if (invitePeerId == null || sessionId == null) return false;

    final peer = _findPeer(invitePeerId);
    if (peer != null) {
      await _sendPrivateMessage(
        peer,
        WalkieControlMessage(
          action: _walkieControlActionCancel,
          sessionId: sessionId,
        ).toWire(),
        allowPlaintextFallback: true,
      );
    }

    _updateWalkie(
      (w) => w.copyWith(
        clearInvite: true,
        clearSessionActivePeerNodeId: true,
        clearLastError: true,
      ),
    );
    return true;
  }

  Future<bool> endSession() async {
    final state = _readState();
    final activePeerId = state.walkie.sessionActivePeerNodeId;
    if (activePeerId == null) {
      _updateWalkie(
        (w) =>
            w.copyWith(clearInvite: true, clearSessionActivePeerNodeId: true),
      );
      return false;
    }

    // inviteSessionId is cleared on accept, so fall back to activePeerId as the
    // session token. The receiver matches on sessionActivePeerNodeId as well,
    // so the message will always be processed correctly.
    final sessionId = state.walkie.inviteSessionId ?? activePeerId;

    final peer = _findPeer(activePeerId);
    if (peer != null) {
      await _sendPrivateMessage(
        peer,
        WalkieControlMessage(
          action: _walkieControlActionEnd,
          sessionId: sessionId,
        ).toWire(),
        allowPlaintextFallback: true,
      );
    }

    _updateWalkie(
      (w) => w.copyWith(
        clearInvite: true,
        clearSessionActivePeerNodeId: true,
        clearLastError: true,
      ),
    );
    return true;
  }

  void handleIncomingControlMessage(
    AirGridMessage msg,
    WalkieControlMessage control,
  ) {
    final peerNodeId = msg.peerNodeId ?? msg.senderNodeId;
    final state = _readState();

    switch (control.action) {
      case _walkieControlActionInvite:
        _updateWalkie(
          (w) => w.copyWith(
            inviteSessionId: control.sessionId,
            invitePeerNodeId: peerNodeId,
            inviteIsIncoming: true,
            peerNodeId: peerNodeId,
            clearLastError: true,
          ),
        );
        if (_isTrustedNode(peerNodeId) && _isWalkieAlwaysOn(peerNodeId)) {
          unawaited(acceptInvite());
        }
        return;
      case _walkieControlActionAccept:
        if (state.walkie.inviteSessionId != control.sessionId &&
            state.walkie.sessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _updateWalkie(
          (w) => w.copyWith(
            sessionActivePeerNodeId: peerNodeId,
            peerNodeId: peerNodeId,
            clearInvite: true,
            clearLastError: true,
          ),
        );
        return;
      case _walkieControlActionDecline:
      case _walkieControlActionCancel:
        if (state.walkie.inviteSessionId != control.sessionId &&
            state.walkie.sessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _updateWalkie(
          (w) => w.copyWith(
            clearInvite: true,
            clearSessionActivePeerNodeId: true,
            isTransmitting: false,
            isSending: false,
            clearLastError: true,
          ),
        );
        return;
      case _walkieControlActionEnd:
        if (state.walkie.inviteSessionId != control.sessionId &&
            state.walkie.sessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _updateWalkie(
          (w) => w.copyWith(
            clearInvite: true,
            clearSessionActivePeerNodeId: true,
            isTransmitting: false,
            isSending: false,
            lastError:
                '${msg.peerName ?? msg.senderName} ended the walkie session',
          ),
        );
        return;
      default:
        return;
    }
  }

  MeshPeer? _findPeer(String nodeId) {
    return _readState().peers.cast<MeshPeer?>().firstWhere(
      (item) => item?.nodeId == nodeId,
      orElse: () => null,
    );
  }
}
