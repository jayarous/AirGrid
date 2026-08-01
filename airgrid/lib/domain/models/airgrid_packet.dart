/// Immutable wire-format packet that travels through the AirGrid mesh.
///
/// Every field is required so the JSON codec can round-trip reliably.
class AirGridPacket {
  final String messageId;
  final String senderNodeId;
  final String senderName;

  /// Unix timestamp in milliseconds.
  final int timestamp;
  final String content;

  /// Ordered list of node IDs that have already processed this packet.
  /// Used for loop-prevention: a node drops packets that already contain its
  /// own nodeId.
  ///
  /// This list should not be mutated. Use [copyWith] with a new list to
  /// create a modified packet (e.g., when adding a node during relay).
  final List<String> seenByNodes;

  /// Remaining allowed hops. Decremented before forwarding; dropped at 0.
  final int hopLimit;

  /// Packet type. "chat" for regular messages, "key_announce" for public-key
  /// distribution packets. Defaults to "chat" for backward compatibility.
  final String packetType;

  /// Sender's base64-encoded X25519 public key. Included in key_announce
  /// packets and optionally in chat packets once encryption is active.
  final String? senderPublicKey;

  /// Encryption scheme version. Null means plaintext.
  final int? encryptionVersion;

  /// Conversation scope: 'public' for mesh broadcast, 'private' for direct.
  /// Defaults to 'public'; omitted from JSON when 'public' for compact wire format.
  final String conversationType;

  /// Intended recipient node id for private packets. Null for public packets.
  final String? recipientNodeId;

  /// ID of the original chat message this packet acknowledges.
  /// Only set for [packetType] values 'delivery_receipt' and 'read_receipt'.
  final String? receiptMessageId;

  // -- Fragment fields (packetType == 'fragment') ------------------------

  /// MessageId of the original (large) packet this fragment belongs to.
  final String? fragmentOf;

  /// Zero-based index of this chunk within the original packet.
  final int? fragmentIndex;

  /// Total number of fragments the original packet was split into.
  final int? fragmentCount;

  // -- Derived behaviour ------------------------------------------------

  /// Whether a relay node should forward this packet.
  ///
  /// Encrypted private packets (including encrypted receipts and fragments)
  /// are relay-eligible because relays cannot read their content.
  /// Plaintext private packets are *never* relayed.
  bool get isRelayEligible =>
      packetType == 'key_announce' ||
      packetType == 'location_update' ||
      (packetType == 'fragment' &&
          (encryptionVersion != null || conversationType == 'public')) ||
      ((packetType == 'delivery_receipt' || packetType == 'read_receipt') &&
          conversationType == 'private' &&
          encryptionVersion != null) ||
      (packetType == 'chat' && conversationType == 'public') ||
      (packetType == 'image' && conversationType == 'public') ||
      (conversationType == 'private' && encryptionVersion != null);

  const AirGridPacket({
    required this.messageId,
    required this.senderNodeId,
    required this.senderName,
    required this.timestamp,
    required this.content,
    required this.seenByNodes,
    required this.hopLimit,
    this.packetType = 'chat',
    this.senderPublicKey,
    this.encryptionVersion,
    this.conversationType = 'public',
    this.recipientNodeId,
    this.receiptMessageId,
    this.fragmentOf,
    this.fragmentIndex,
    this.fragmentCount,
  });

  factory AirGridPacket.fromJson(Map<String, dynamic> json) {
    return AirGridPacket(
      messageId: json['messageId'] as String,
      senderNodeId: json['senderNodeId'] as String,
      senderName: json['senderName'] as String,
      timestamp: json['timestamp'] as int,
      content: json['content'] as String,
      seenByNodes: List<String>.from(json['seenByNodes'] as List),
      hopLimit: json['hopLimit'] as int,
      packetType: json['packetType'] as String? ?? 'chat',
      senderPublicKey: json['senderPublicKey'] as String?,
      encryptionVersion: json['encryptionVersion'] as int?,
      conversationType: json['conversationType'] as String? ?? 'public',
      recipientNodeId: json['recipientNodeId'] as String?,
      receiptMessageId: json['receiptMessageId'] as String?,
      fragmentOf: json['fragmentOf'] as String?,
      fragmentIndex: json['fragmentIndex'] as int?,
      fragmentCount: json['fragmentCount'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'senderNodeId': senderNodeId,
    'senderName': senderName,
    'timestamp': timestamp,
    'content': content,
    'seenByNodes': seenByNodes,
    'hopLimit': hopLimit,
    'packetType': packetType,
    if (senderPublicKey != null) 'senderPublicKey': senderPublicKey,
    if (encryptionVersion != null) 'encryptionVersion': encryptionVersion,
    if (conversationType != 'public') 'conversationType': conversationType,
    if (recipientNodeId != null) 'recipientNodeId': recipientNodeId,
    if (receiptMessageId != null) 'receiptMessageId': receiptMessageId,
    if (fragmentOf != null) 'fragmentOf': fragmentOf,
    if (fragmentIndex != null) 'fragmentIndex': fragmentIndex,
    if (fragmentCount != null) 'fragmentCount': fragmentCount,
  };

  AirGridPacket copyWith({
    String? messageId,
    String? senderNodeId,
    String? senderName,
    int? timestamp,
    String? content,
    List<String>? seenByNodes,
    int? hopLimit,
    String? packetType,
    String? senderPublicKey,
    int? encryptionVersion,
    String? conversationType,
    String? recipientNodeId,
    String? receiptMessageId,
    String? fragmentOf,
    int? fragmentIndex,
    int? fragmentCount,
  }) {
    return AirGridPacket(
      messageId: messageId ?? this.messageId,
      senderNodeId: senderNodeId ?? this.senderNodeId,
      senderName: senderName ?? this.senderName,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      seenByNodes: seenByNodes ?? this.seenByNodes,
      hopLimit: hopLimit ?? this.hopLimit,
      packetType: packetType ?? this.packetType,
      senderPublicKey: senderPublicKey ?? this.senderPublicKey,
      encryptionVersion: encryptionVersion ?? this.encryptionVersion,
      conversationType: conversationType ?? this.conversationType,
      recipientNodeId: recipientNodeId ?? this.recipientNodeId,
      receiptMessageId: receiptMessageId ?? this.receiptMessageId,
      fragmentOf: fragmentOf ?? this.fragmentOf,
      fragmentIndex: fragmentIndex ?? this.fragmentIndex,
      fragmentCount: fragmentCount ?? this.fragmentCount,
    );
  }

  @override
  String toString() =>
      'AirGridPacket(id=$messageId, from=$senderNodeId, hop=$hopLimit, type=$packetType, conv=$conversationType)';
}
