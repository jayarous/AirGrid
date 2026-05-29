/// Represents a currently-connected peer in the mesh.
class MeshPeer {
  final String endpointId;
  final String displayName;
  final DateTime connectedAt;

  /// Stable node id, populated once a direct [key_announce] is received.
  final String? nodeId;

  /// True once the peer's public key is cached and private encryption is ready.
  final bool encryptionReady;

  const MeshPeer({
    required this.endpointId,
    required this.displayName,
    required this.connectedAt,
    this.nodeId,
    this.encryptionReady = false,
  });

  MeshPeer copyWith({
    String? endpointId,
    String? displayName,
    DateTime? connectedAt,
    String? nodeId,
    bool? encryptionReady,
  }) {
    return MeshPeer(
      endpointId: endpointId ?? this.endpointId,
      displayName: displayName ?? this.displayName,
      connectedAt: connectedAt ?? this.connectedAt,
      nodeId: nodeId ?? this.nodeId,
      encryptionReady: encryptionReady ?? this.encryptionReady,
    );
  }

  @override
  String toString() =>
      'MeshPeer(endpoint=$endpointId, name=$displayName, nodeId=$nodeId, ready=$encryptionReady)';
}
