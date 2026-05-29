/// Identifies which conversation thread is currently selected in the chat UI.
sealed class ConversationTarget {
  const ConversationTarget();
}

/// The default public mesh broadcast thread.
class PublicConversation extends ConversationTarget {
  const PublicConversation();
}

/// A direct private thread with a specific peer, keyed by stable node id.
class PrivateConversation extends ConversationTarget {
  final String peerNodeId;
  final String peerName;

  const PrivateConversation({required this.peerNodeId, required this.peerName});

  @override
  bool operator ==(Object other) =>
      other is PrivateConversation && other.peerNodeId == peerNodeId;

  @override
  int get hashCode => peerNodeId.hashCode;
}
