import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AirGridMessage buildMessage({
    required String id,
    required String conversationType,
    required String content,
    String? peerNodeId,
  }) {
    return AirGridMessage(
      id: id,
      senderNodeId: 'peer-1',
      senderName: 'Alex',
      timestamp: DateTime.now(),
      content: content,
      isLocal: false,
      conversationType: conversationType,
      peerNodeId: peerNodeId,
      messageKind: content == '[walkie]' || content == '[voice]'
          ? 'audio'
          : 'text',
    );
  }

  test('filteredMessages excludes walkie entries from private thread', () {
    final state = ChatState.initial().copyWith(
      selectedConversation: const PrivateConversation(
        peerNodeId: 'peer-1',
        peerName: 'Alex',
      ),
      messages: [
        buildMessage(
          id: 'm1',
          conversationType: 'private',
          content: '[walkie]',
          peerNodeId: 'peer-1',
        ),
        buildMessage(
          id: 'm2',
          conversationType: 'private',
          content: '[voice]',
          peerNodeId: 'peer-1',
        ),
      ],
    );

    final visible = state.filteredMessages;
    expect(visible.length, 1);
    expect(visible.single.id, 'm2');
  });

  test('filteredMessages excludes walkie entries from public thread', () {
    final state = ChatState.initial().copyWith(
      selectedConversation: const PublicConversation(),
      messages: [
        buildMessage(id: 'm1', conversationType: 'public', content: '[walkie]'),
        buildMessage(id: 'm2', conversationType: 'public', content: 'hello'),
      ],
    );

    final visible = state.filteredMessages;
    expect(visible.length, 1);
    expect(visible.single.id, 'm2');
  });
}
