/// A mesh peer whose identity has been observed at least once via a
/// [key_announce] packet (direct or relayed).
///
/// Keyed by stable [nodeId]. Persisted across sessions so that encrypted
/// private messages can be addressed to contacts who are not currently
/// directly connected.
class KnownContact {
  final String nodeId;
  final String displayName;

  /// Optional remote profile icon ID advertised by the peer.
  final String? profileIconId;

  /// Optional remote profile status advertised by the peer.
  final String? profileStatus;

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

  /// Whether private walkie should auto-start for this contact whenever they
  /// are selected and online.
  final bool walkieAlwaysOn;

  /// Whether the remote peer reports they can receive private walkie right now
  /// (e.g. they are on the private walkie screen or have an availability flag).
  final bool remoteWalkieAvailable;

  /// Whether this private chat is hidden from the default conversation list.
  ///
  /// Closing is local-only and does not remove message history.
  final bool isChatClosed;

  const KnownContact({
    required this.nodeId,
    required this.displayName,
    this.profileIconId,
    this.profileStatus,
    required this.publicKeyBase64,
    required this.lastSeenAt,
    this.lastEndpointId,
    this.isBlocked = false,
    this.isTrusted = false,
    this.walkieAlwaysOn = false,
    this.remoteWalkieAvailable = false,
    this.isChatClosed = false,
  });

  /// True when this contact is a currently connected direct peer.
  bool get isDirectlyConnected => lastEndpointId != null;

  KnownContact copyWith({
    String? displayName,
    String? profileIconId,
    String? profileStatus,
    String? publicKeyBase64,
    DateTime? lastSeenAt,
    String? lastEndpointId,
    bool clearEndpointId = false,
    bool? isBlocked,
    bool? isTrusted,
    bool? walkieAlwaysOn,
    bool? remoteWalkieAvailable,
    bool? isChatClosed,
  }) {
    return KnownContact(
      nodeId: nodeId,
      displayName: displayName ?? this.displayName,
      profileIconId: profileIconId ?? this.profileIconId,
      profileStatus: profileStatus ?? this.profileStatus,
      publicKeyBase64: publicKeyBase64 ?? this.publicKeyBase64,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastEndpointId: clearEndpointId
          ? null
          : lastEndpointId ?? this.lastEndpointId,
      isBlocked: isBlocked ?? this.isBlocked,
      isTrusted: isTrusted ?? this.isTrusted,
      walkieAlwaysOn: walkieAlwaysOn ?? this.walkieAlwaysOn,
      remoteWalkieAvailable: remoteWalkieAvailable ?? this.remoteWalkieAvailable,
      isChatClosed: isChatClosed ?? this.isChatClosed,
    );
  }

  /// Wire-format serialisation. [lastEndpointId] is ephemeral and is never
  /// persisted.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'displayName': displayName,
    if (profileIconId != null) 'profileIconId': profileIconId,
    if (profileStatus != null) 'profileStatus': profileStatus,
    'publicKeyBase64': publicKeyBase64,
    'lastSeenAt': lastSeenAt.millisecondsSinceEpoch,
    'isBlocked': isBlocked,
    'isTrusted': isTrusted,
    'walkieAlwaysOn': walkieAlwaysOn,
    'remoteWalkieAvailable': remoteWalkieAvailable,
    'isChatClosed': isChatClosed,
  };

  factory KnownContact.fromJson(Map<String, dynamic> json) => KnownContact(
    nodeId: json['nodeId'] as String,
    displayName: json['displayName'] as String,
    profileIconId: json['profileIconId'] as String?,
    profileStatus: json['profileStatus'] as String?,
    publicKeyBase64: json['publicKeyBase64'] as String,
    lastSeenAt: DateTime.fromMillisecondsSinceEpoch(json['lastSeenAt'] as int),
    isBlocked: json['isBlocked'] as bool? ?? false,
    isTrusted: json['isTrusted'] as bool? ?? false,
    walkieAlwaysOn: json['walkieAlwaysOn'] as bool? ?? false,
    remoteWalkieAvailable: json['remoteWalkieAvailable'] as bool? ?? false,
    isChatClosed: json['isChatClosed'] as bool? ?? false,
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
