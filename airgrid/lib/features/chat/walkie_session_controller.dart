import 'dart:async';
import 'dart:convert';

import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_state.dart';
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

  const WalkieControlMessage({
    required this.action,
    required this.sessionId,
  });

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

  Future<bool> sendInvite(MeshPeer peer) async {
    final nodeId = peer.nodeId;
    if (nodeId == null) return false;

    final sessionId = const Uuid().v4();
    _writeState(
      _readState().copyWith(
        walkieInviteSessionId: sessionId,
        walkieInvitePeerNodeId: nodeId,
        walkieInviteIsIncoming: false,
        walkiePeerNodeId: nodeId,
        clearWalkieLastError: true,
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

    _writeState(
      _readState().copyWith(
        walkieLastError: 'Failed to send invite',
        clearWalkieInvite: true,
        clearWalkieSessionActivePeerNodeId: true,
      ),
    );
    return false;
  }

  Future<bool> acceptInvite() async {
    final state = _readState();
    final invitePeerId = state.walkieInvitePeerNodeId;
    final sessionId = state.walkieInviteSessionId;
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
      _writeState(_readState().copyWith(walkieLastError: 'Failed to accept invite'));
      return false;
    }

    _writeState(
      _readState().copyWith(
        walkieSessionActivePeerNodeId: invitePeerId,
        walkiePeerNodeId: invitePeerId,
        clearWalkieInvite: true,
        clearWalkieLastError: true,
      ),
    );
    return true;
  }

  Future<bool> declineInvite() async {
    final state = _readState();
    final invitePeerId = state.walkieInvitePeerNodeId;
    final sessionId = state.walkieInviteSessionId;
    if (invitePeerId == null || sessionId == null) {
      return false;
    }

    final peer = _findPeer(invitePeerId);
    if (peer == null) {
      _writeState(_readState().copyWith(clearWalkieInvite: true));
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

    _writeState(
      _readState().copyWith(clearWalkieInvite: true, clearWalkieLastError: true),
    );
    return true;
  }

  Future<bool> cancelInvite() async {
    final state = _readState();
    final invitePeerId = state.walkieInvitePeerNodeId;
    final sessionId = state.walkieInviteSessionId;
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

    _writeState(
      _readState().copyWith(
        clearWalkieInvite: true,
        clearWalkieSessionActivePeerNodeId: true,
        clearWalkieLastError: true,
      ),
    );
    return true;
  }

  Future<bool> endSession() async {
    final state = _readState();
    final activePeerId = state.walkieSessionActivePeerNodeId;
    if (activePeerId == null) {
      _writeState(
        _readState().copyWith(
          clearWalkieInvite: true,
          clearWalkieSessionActivePeerNodeId: true,
        ),
      );
      return false;
    }

    // walkieInviteSessionId is cleared on accept, so fall back to activePeerId
    // as the session token. The receiver matches on walkieSessionActivePeerNodeId
    // as well, so the message will always be processed correctly.
    final sessionId = state.walkieInviteSessionId ?? activePeerId;

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

    _writeState(
      _readState().copyWith(
        clearWalkieInvite: true,
        clearWalkieSessionActivePeerNodeId: true,
        clearWalkieLastError: true,
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
        _writeState(
          state.copyWith(
            walkieInviteSessionId: control.sessionId,
            walkieInvitePeerNodeId: peerNodeId,
            walkieInviteIsIncoming: true,
            walkiePeerNodeId: peerNodeId,
            clearWalkieLastError: true,
          ),
        );
        if (_isTrustedNode(peerNodeId) && _isWalkieAlwaysOn(peerNodeId)) {
          unawaited(acceptInvite());
        }
        return;
      case _walkieControlActionAccept:
        if (state.walkieInviteSessionId != control.sessionId &&
            state.walkieSessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _writeState(
          state.copyWith(
            walkieSessionActivePeerNodeId: peerNodeId,
            walkiePeerNodeId: peerNodeId,
            clearWalkieInvite: true,
            clearWalkieLastError: true,
          ),
        );
        return;
      case _walkieControlActionDecline:
      case _walkieControlActionCancel:
        if (state.walkieInviteSessionId != control.sessionId &&
            state.walkieSessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _writeState(
          state.copyWith(
            clearWalkieInvite: true,
            clearWalkieSessionActivePeerNodeId: true,
            walkieIsTransmitting: false,
            walkieIsSending: false,
            clearWalkieLastError: true,
          ),
        );
        return;
      case _walkieControlActionEnd:
        if (state.walkieInviteSessionId != control.sessionId &&
            state.walkieSessionActivePeerNodeId != peerNodeId) {
          return;
        }
        _writeState(
          state.copyWith(
            clearWalkieInvite: true,
            clearWalkieSessionActivePeerNodeId: true,
            walkieIsTransmitting: false,
            walkieIsSending: false,
            walkieLastError:
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
