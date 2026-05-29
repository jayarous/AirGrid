import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/peer_location.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/features/chat/conversation_target.dart';

/// Immutable snapshot of the chat + mesh state shown in the UI.
class ChatState {
  final List<AirGridMessage> messages;
  final List<MeshPeer> peers;
  final bool isAdvertising;
  final bool isDiscovering;
  final bool meshStarted;
  final bool isMeshStarting;
  final bool playServicesAvailable;
  final String playServicesCode;
  final String playServicesMessage;
  final bool playServicesCanResolve;
  final String? lastEvent;
  final ConversationTarget selectedConversation;
  final Map<String, int> unreadPrivateCounts;
  final PeerLocation? localLocation;
  final Map<String, PeerLocation> peerLocations;
  final bool isLocationSharing;
  final String? locationStatus;
  final List<KnownContact> knownContacts;
  final PrivacyMode privacyMode;
  final bool batteryOptimizationEnabled;

  /// Message IDs hidden by the local user this session. In-memory only.
  final Set<String> hiddenMessageIds;

  const ChatState({
    required this.messages,
    required this.peers,
    required this.isAdvertising,
    required this.isDiscovering,
    required this.meshStarted,
    required this.isMeshStarting,
    required this.playServicesAvailable,
    required this.playServicesCode,
    required this.playServicesMessage,
    required this.playServicesCanResolve,
    required this.lastEvent,
    this.selectedConversation = const PublicConversation(),
    this.unreadPrivateCounts = const {},
    this.localLocation,
    this.peerLocations = const {},
    this.isLocationSharing = false,
    this.locationStatus,
    this.knownContacts = const [],
    this.privacyMode = PrivacyMode.everyoneNearby,
    this.batteryOptimizationEnabled = true,
    this.hiddenMessageIds = const {},
  });

  const ChatState.initial()
    : messages = const [],
      peers = const [],
      isAdvertising = false,
      isDiscovering = false,
      meshStarted = false,
      isMeshStarting = false,
      playServicesAvailable = true,
      playServicesCode = 'available',
      playServicesMessage = 'Google Play Services is available.',
      playServicesCanResolve = false,
      lastEvent = null,
      selectedConversation = const PublicConversation(),
      unreadPrivateCounts = const {},
      localLocation = null,
      peerLocations = const {},
      isLocationSharing = false,
      locationStatus = null,
      knownContacts = const [],
      privacyMode = PrivacyMode.everyoneNearby,
      batteryOptimizationEnabled = true,
      hiddenMessageIds = const {};

  /// Messages filtered to the currently selected conversation.
  List<AirGridMessage> get filteredMessages {
    final blocked = blockedNodeIds;
    final hidden = hiddenMessageIds;
    final conv = selectedConversation;
    if (conv is PublicConversation) {
      return messages
          .where(
            (m) =>
                m.conversationType == 'public' &&
                !blocked.contains(m.senderNodeId) &&
                !hidden.contains(m.id),
          )
          .toList();
    } else if (conv is PrivateConversation) {
      return messages
          .where(
            (m) =>
                m.conversationType == 'private' &&
                m.peerNodeId == conv.peerNodeId &&
                !blocked.contains(m.senderNodeId) &&
                (m.peerNodeId == null || !blocked.contains(m.peerNodeId)) &&
                !hidden.contains(m.id),
          )
          .toList();
    }
    return messages;
  }

  int unreadCountFor(String peerNodeId) => unreadPrivateCounts[peerNodeId] ?? 0;

  /// Node IDs of all blocked contacts, for O(1) look-up.
  Set<String> get blockedNodeIds =>
      knownContacts.where((c) => c.isBlocked).map((c) => c.nodeId).toSet();

  /// Node IDs of all trusted contacts, for O(1) look-up.
  Set<String> get trustedNodeIds =>
      knownContacts.where((c) => c.isTrusted).map((c) => c.nodeId).toSet();

  ChatState copyWith({
    List<AirGridMessage>? messages,
    List<MeshPeer>? peers,
    bool? isAdvertising,
    bool? isDiscovering,
    bool? meshStarted,
    bool? isMeshStarting,
    bool? playServicesAvailable,
    String? playServicesCode,
    String? playServicesMessage,
    bool? playServicesCanResolve,
    String? lastEvent,
    ConversationTarget? selectedConversation,
    Map<String, int>? unreadPrivateCounts,
    PeerLocation? localLocation,
    Map<String, PeerLocation>? peerLocations,
    bool? isLocationSharing,
    String? locationStatus,
    List<KnownContact>? knownContacts,
    PrivacyMode? privacyMode,
    bool? batteryOptimizationEnabled,
    Set<String>? hiddenMessageIds,
    bool clearLocalLocation = false,
    bool clearLocationStatus = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      peers: peers ?? this.peers,
      isAdvertising: isAdvertising ?? this.isAdvertising,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      meshStarted: meshStarted ?? this.meshStarted,
      isMeshStarting: isMeshStarting ?? this.isMeshStarting,
      playServicesAvailable:
          playServicesAvailable ?? this.playServicesAvailable,
      playServicesCode: playServicesCode ?? this.playServicesCode,
      playServicesMessage: playServicesMessage ?? this.playServicesMessage,
      playServicesCanResolve:
          playServicesCanResolve ?? this.playServicesCanResolve,
      lastEvent: lastEvent ?? this.lastEvent,
      selectedConversation: selectedConversation ?? this.selectedConversation,
      unreadPrivateCounts: unreadPrivateCounts ?? this.unreadPrivateCounts,
      localLocation: clearLocalLocation
          ? null
          : localLocation ?? this.localLocation,
      peerLocations: peerLocations ?? this.peerLocations,
      isLocationSharing: isLocationSharing ?? this.isLocationSharing,
      locationStatus: clearLocationStatus
          ? null
          : locationStatus ?? this.locationStatus,
      knownContacts: knownContacts ?? this.knownContacts,
      privacyMode: privacyMode ?? this.privacyMode,
      batteryOptimizationEnabled:
          batteryOptimizationEnabled ?? this.batteryOptimizationEnabled,
      hiddenMessageIds: hiddenMessageIds ?? this.hiddenMessageIds,
    );
  }
}
