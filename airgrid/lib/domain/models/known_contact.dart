/// A mesh peer whose identity has been observed at least once via a
/// [key_announce] packet (direct or relayed).
///
/// Keyed by stable [nodeId]. Persisted across sessions so that encrypted
/// private messages can be addressed to contacts who are not currently
/// directly connected.
class KnownContact {
  final String nodeId;
  final String displayName;

  /// Base64-encoded X25519 public key received from the peer.
  final String publicKeyBase64;

  /// Wall-clock time of the most recent [key_announce] from this node.
  final DateTime lastSeenAt;

  /// Endpoint ID of the currently connected direct peer session, or null when
  /// the contact is offline / only known via relay.
  final String? lastEndpointId;

  /// Whether the local user has blocked this contact.
  ///
  /// Blocking is local-only and never communicated to the peer.
  final bool isBlocked;

  /// Whether the local user has explicitly trusted this contact.
  ///
  /// Relevant only when [PrivacyMode.trustedContactsOnly] is active.
  /// Trust is local-only and never communicated to the peer.
  final bool isTrusted;

  const KnownContact({
    required this.nodeId,
    required this.displayName,
    required this.publicKeyBase64,
    required this.lastSeenAt,
    this.lastEndpointId,
    this.isBlocked = false,
    this.isTrusted = false,
  });

  /// True when this contact is a currently connected direct peer.
  bool get isDirectlyConnected => lastEndpointId != null;

  KnownContact copyWith({
    String? displayName,
    String? publicKeyBase64,
    DateTime? lastSeenAt,
    String? lastEndpointId,
    bool clearEndpointId = false,
    bool? isBlocked,
    bool? isTrusted,
  }) {
    return KnownContact(
      nodeId: nodeId,
      displayName: displayName ?? this.displayName,
      publicKeyBase64: publicKeyBase64 ?? this.publicKeyBase64,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastEndpointId: clearEndpointId
          ? null
          : lastEndpointId ?? this.lastEndpointId,
      isBlocked: isBlocked ?? this.isBlocked,
      isTrusted: isTrusted ?? this.isTrusted,
    );
  }

  /// Wire-format serialisation. [lastEndpointId] is ephemeral and is never
  /// persisted.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'displayName': displayName,
    'publicKeyBase64': publicKeyBase64,
    'lastSeenAt': lastSeenAt.millisecondsSinceEpoch,
    'isBlocked': isBlocked,
    'isTrusted': isTrusted,
  };

  factory KnownContact.fromJson(Map<String, dynamic> json) => KnownContact(
    nodeId: json['nodeId'] as String,
    displayName: json['displayName'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    lastSeenAt: DateTime.fromMillisecondsSinceEpoch(json['lastSeenAt'] as int),
    isBlocked: json['isBlocked'] as bool? ?? false,
    isTrusted: json['isTrusted'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is KnownContact && other.nodeId == nodeId;

  @override
  int get hashCode => nodeId.hashCode;

  @override
  String toString() =>
      'KnownContact(nodeId=$nodeId, name=$displayName, direct=$isDirectlyConnected)';
}
