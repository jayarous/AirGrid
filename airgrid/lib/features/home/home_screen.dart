import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/profile/peer_profile_sheet.dart';
import 'package:airgrid/features/settings/profile_avatar_catalog.dart';
import 'package:airgrid/features/walkie/public_walkie_status_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  MeshPermissionsSnapshot? _permissionsSnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatControllerProvider.notifier).startMesh();
    });
    _refreshPermissionStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
    }
    ref.read(chatControllerProvider.notifier).handleAppLifecycleState(state);
  }

  Future<void> _refreshPermissionStatus() async {
    final snapshot = await ref.read(meshPermissionsProvider).checkStatuses();
    if (!mounted) return;
    setState(() => _permissionsSnapshot = snapshot);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).pushNamed(AppRouter.settings);
    if (!mounted) return;
    await _refreshPermissionStatus();
  }

  Future<void> _resolvePlayServices() async {
    final state = ref.read(chatControllerProvider);
    final resolved = await ref
        .read(playServicesProvider)
        .resolve(
          PlayServicesStatus(
            available: state.playServicesAvailable,
            code: state.playServicesCode,
            message: state.playServicesMessage,
            canResolve: state.playServicesCanResolve,
          ),
        );
    if (!resolved && mounted) {
      await _openSettings();
    }
  }

  Future<void> _exitApp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exit AirGrid?'),
        content: const Text('This will close the app.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(chatControllerProvider.notifier).stopMesh();
      if (!mounted) return;
      await SystemNavigator.pop();
    }
  }

  void _openPublicChat() {
    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(const PublicConversation());
    Navigator.of(context).pushNamed(AppRouter.chat);
  }

  void _openPrivateChat(MeshPeer peer) {
    final nodeId = peer.nodeId;
    if (nodeId == null) return;
    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(
          PrivateConversation(peerNodeId: nodeId, peerName: peer.displayName),
        );
    Navigator.of(context).pushNamed(AppRouter.chat);
  }

  void _openWalkie() {
    unawaited(Navigator.of(context).pushNamed(AppRouter.walkie));
  }

  void _openFirstUnreadPrivateChat(ChatState state) {
    String? peerNodeId;
    for (final entry in state.unreadPrivateCounts.entries) {
      if (entry.value > 0) {
        peerNodeId = entry.key;
        break;
      }
    }
    if (peerNodeId == null) {
      Navigator.of(context).pushNamed(AppRouter.chat);
      return;
    }

    final peer = state.peers.cast<MeshPeer?>().firstWhere(
      (p) => p?.nodeId == peerNodeId,
      orElse: () => null,
    );
    final matchingMessage = state.messages.cast<AirGridMessage?>().firstWhere(
      (m) => m?.conversationType == 'private' && m?.peerNodeId == peerNodeId,
      orElse: () => null,
    );

    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(
          PrivateConversation(
            peerNodeId: peerNodeId,
            peerName:
                peer?.displayName ??
                matchingMessage?.peerName ??
                matchingMessage?.senderName ??
                'Private chat',
          ),
        );
    Navigator.of(context).pushNamed(AppRouter.chat);
  }

  Future<void> _toggleHomeAdvertising() async {
    final state = ref.read(chatControllerProvider);
    final controlsEnabled =
        state.playServicesAvailable && state.meshStarted && !state.isMeshStarting;
    if (!controlsEnabled) return;

    final next = !state.isAdvertising;
    await ref.read(chatControllerProvider.notifier).setAdvertisingEnabled(next);
    if (!mounted || !next) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Others AirGrid users nearby can find you'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleHomeDiscovering() async {
    final state = ref.read(chatControllerProvider);
    final controlsEnabled =
        state.playServicesAvailable && state.meshStarted && !state.isMeshStarting;
    if (!controlsEnabled) return;

    final next = !state.isDiscovering;
    await ref.read(chatControllerProvider.notifier).setDiscoveryEnabled(next);
    if (!mounted || !next) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Looking for nearby AirGrid users'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _refreshHome() async {
    await _refreshPermissionStatus();
    if (!mounted) return;
    await ref.read(chatControllerProvider.notifier).startMesh(forceRestart: true);
  }

  Future<void> _refreshPeersFromChip() async {
    unawaited(HapticFeedback.selectionClick());
    await _refreshHome();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(localIdentityStoreProvider);
    final state = ref.watch(chatControllerProvider);
    final cs = Theme.of(context).colorScheme;
    final displayName = identity.displayName?.trim();
    final profileStatus = identity.profileStatus?.trim();
    final profileIcon = ProfileAvatarCatalog.iconFor(identity.profileIconId);
    final isOnline = state.meshStarted;
    final missingPermissions =
        _permissionsSnapshot?.hasMissingCriticalPermissions ?? false;
    final recentMessages = state.messages.take(3).toList();
    final unreadPrivateTotal = state.unreadPrivateCounts.values.fold<int>(
      0,
      (sum, count) => sum + count,
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: cs.surface.withAlpha(240),
        title: Image.asset(
          'assets/images/airgrid_horizontal.png',
          height: 32,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
        ),
        titleSpacing: 16,
        actions: [
          const PublicWalkieStatusIcon(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            tooltip: 'Exit app',
            onPressed: _exitApp,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshHome,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          children: [
            Row(
              children: [
                ProfileAvatarBadge(
                  icon: profileIcon,
                  isOnline: isOnline,
                  radius: 26,
                  backgroundColor: cs.primaryContainer,
                  iconColor: cs.onPrimaryContainer,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
              displayName == null || displayName.isEmpty
                  ? 'Hello'
                  : 'Hello, $displayName',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
            if (profileStatus != null && profileStatus.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                profileStatus,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (missingPermissions) ...[
              _ActionBanner(
                icon: Icons.security,
                title: 'Permissions needed',
                message:
                    'Bluetooth and Wi-Fi access are required before nearby devices can join your mesh.',
                actionLabel: 'Fix',
                onAction: _openSettings,
              ),
              const SizedBox(height: 12),
            ],
            if (!state.playServicesAvailable) ...[
              _ActionBanner(
                icon: Icons.error_outline,
                title: 'Nearby is unavailable',
                message: state.playServicesMessage,
                actionLabel: state.playServicesCanResolve ? 'Fix' : null,
                onAction: state.playServicesCanResolve
                    ? _resolvePlayServices
                    : null,
              ),
              const SizedBox(height: 12),
            ],
            _MeshOverviewCard(
              peerCount: state.peers.length,
              meshStarted: state.meshStarted,
              isStarting: state.isMeshStarting,
              isAdvertising: state.isAdvertising,
              isDiscovering: state.isDiscovering,
              isBlocked: !state.playServicesAvailable,
              statusLine: _statusLineFor(state),
              lastEvent: state.lastEvent,
              onToggleMesh: state.meshStarted
                  ? ref.read(chatControllerProvider.notifier).stopMesh
                  : ref.read(chatControllerProvider.notifier).startMesh,
              onRefreshPeers: _refreshPeersFromChip,
              onToggleAdvertising: _toggleHomeAdvertising,
              onToggleDiscovering: _toggleHomeDiscovering,
            ),
            const SizedBox(height: 24),
            _QuickActions(
              onOpenPublicChat: _openPublicChat,
              onOpenNearby: () =>
                  unawaited(Navigator.of(context).pushNamed(AppRouter.nearby)),
              onOpenWalkie: _openWalkie,
            ),
            if (unreadPrivateTotal > 0) ...[
              const SizedBox(height: 12),
              _UnreadPrivateBanner(
                count: unreadPrivateTotal,
                onTap: () => _openFirstUnreadPrivateChat(state),
              ),
            ],
            const SizedBox(height: 28),
            _SectionHeader(
              title: 'Nearby Peers',
              trailing: unreadPrivateTotal > 0
                  ? '$unreadPrivateTotal unread'
                  : '${state.peers.length}',
            ),
            const SizedBox(height: 8),
            if (state.peers.isEmpty)
              _EmptyPanel(
                icon: state.playServicesAvailable
                    ? Icons.travel_explore
                    : Icons.error_outline,
                title: state.playServicesAvailable
                    ? 'Scanning for devices'
                    : 'Nearby unavailable',
                message: state.playServicesAvailable
                    ? 'Keep AirGrid open nearby to discover peers.'
                    : state.playServicesMessage,
              )
            else
              ...state.peers.map(
                (peer) {
                  final contact = peer.nodeId == null
                      ? null
                      : state.knownContacts.cast<KnownContact?>().firstWhere(
                          (c) => c?.nodeId == peer.nodeId,
                          orElse: () => null,
                        );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _PeerTile(
                      peer: peer,
                      unreadCount: peer.nodeId == null
                          ? 0
                          : state.unreadCountFor(peer.nodeId!),
                      onTap: peer.nodeId == null
                          ? null
                          : () => _openPrivateChat(peer),
                      onLongPress: peer.nodeId == null
                          ? null
                          : () {
                              showPeerProfileSheet(
                                context,
                                PeerProfileSnapshot(
                                  displayName: peer.displayName,
                                  nodeId: peer.nodeId!,
                                  profileIconId: contact?.profileIconId,
                                  profileStatus: contact?.profileStatus,
                                  isOnline: true,
                                ),
                              );
                            },
                    ),
                  );
                },
              ),
            const SizedBox(height: 12),
            _SectionHeader(
              title: 'Recent Activity',
              trailing: state.messages.isEmpty
                  ? null
                  : '${state.messages.length}',
            ),
            const SizedBox(height: 8),
            if (recentMessages.isEmpty)
              const _EmptyPanel(
                icon: Icons.chat_bubble_outline,
                title: 'No messages yet',
                message: 'Open public chat when you are ready to broadcast.',
              )
            else
              ...recentMessages.map(
                (message) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RecentMessageTile(message: message),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        elevation: 4,
        hoverElevation: 6,
        focusElevation: 6,
        highlightElevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        onPressed: _openPublicChat,
        icon: const Icon(Icons.forum_rounded),
        label: const Text('Public Chat', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),
      ),
    );
  }
}

String _statusLineFor(ChatState state) {
  if (state.isMeshStarting) return 'Starting the local mesh...';
  if (!state.playServicesAvailable) return 'Mesh is disabled on this device.';
  if (!state.meshStarted) return 'Mesh is off.';
  if (state.peers.isEmpty) return 'Broadcasting and scanning nearby.';
  return 'Connected to ${state.peers.length} nearby peer${state.peers.length == 1 ? '' : 's'}.';
}

class _MeshOverviewCard extends StatelessWidget {
  final int peerCount;
  final bool meshStarted;
  final bool isStarting;
  final bool isAdvertising;
  final bool isDiscovering;
  final bool isBlocked;
  final String statusLine;
  final String? lastEvent;
  final Future<void> Function() onToggleMesh;
  final Future<void> Function() onRefreshPeers;
  final Future<void> Function() onToggleAdvertising;
  final Future<void> Function() onToggleDiscovering;

  const _MeshOverviewCard({
    required this.peerCount,
    required this.meshStarted,
    required this.isStarting,
    required this.isAdvertising,
    required this.isDiscovering,
    required this.isBlocked,
    required this.statusLine,
    required this.lastEvent,
    required this.onToggleMesh,
    required this.onRefreshPeers,
    required this.onToggleAdvertising,
    required this.onToggleDiscovering,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final online = meshStarted && !isBlocked;
    const onlineIconBackground = Color(0xFFDCFCE7);
    const onlineIconColor = Color(0xFF16A34A);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(90)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: online ? onlineIconBackground : cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  online ? Icons.hub_rounded : Icons.hub_outlined,
                  color: online ? onlineIconColor : cs.onErrorContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online ? 'Mesh Online' : 'Mesh Offline',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      lastEvent ?? 'Waiting for transport status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  onPressed: isStarting ? null : onToggleMesh,
                  tooltip: meshStarted ? 'Stop mesh' : 'Start mesh',
                  icon: isStarting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          meshStarted ? Icons.power_settings_new : Icons.wifi,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _MetricChip(
                        icon: Icons.people_outline,
                        label: '$peerCount peer${peerCount == 1 ? '' : 's'}',
                        active: peerCount > 0,
                        color: Colors.teal,
                        onTap: !isStarting ? onRefreshPeers : null,
                      ),
                      const SizedBox(width: 8),
                      _MetricChip(
                        icon: Icons.campaign_outlined,
                        label: online ? 'Available' : 'Offline',
                        active: online && isAdvertising,
                        color: Colors.green,
                        onTap: online ? onToggleAdvertising : null,
                      ),
                      const SizedBox(width: 8),
                      _MetricChip(
                        icon: Icons.search,
                        label: online ? 'Scanning' : 'Idle',
                        active: online && isDiscovering,
                        color: Colors.orange,
                        onTap: online ? onToggleDiscovering : null,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            statusLine,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final VoidCallback onOpenPublicChat;
  final VoidCallback onOpenNearby;
  final VoidCallback onOpenWalkie;

  const _QuickActions({
    required this.onOpenPublicChat,
    required this.onOpenNearby,
    required this.onOpenWalkie,
  });

  Widget _buildActionCard(BuildContext context, String title, IconData icon, VoidCallback onTap, {bool isPrimary = false}) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: isPrimary ? cs.primary : cs.surfaceContainerHighest.withAlpha(150),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: isPrimary ? cs.onPrimary : cs.primary,
                  size: 28,
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    color: isPrimary ? cs.onPrimary : cs.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _buildActionCard(context, 'Public', Icons.forum_rounded, onOpenPublicChat, isPrimary: true),
        const SizedBox(width: 12),
        _buildActionCard(context, 'Nearby', Icons.radar_rounded, onOpenNearby),
        const SizedBox(width: 12),
        _buildActionCard(context, 'Walkie', Icons.keyboard_voice_rounded, onOpenWalkie),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: cs.primary),
          ),
      ],
    );
  }
}

class _PeerTile extends StatelessWidget {
  final MeshPeer peer;
  final int unreadCount;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _PeerTile({
    required this.peer,
    required this.unreadCount,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canMessage = peer.nodeId != null;

    return Card(
      elevation: 0,
      color: cs.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withAlpha(50)),
      ),
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: canMessage ? cs.primaryContainer : cs.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Icon(
            canMessage ? Icons.person_rounded : Icons.sync_rounded,
            color: canMessage ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
        ),
        title: Text(
          peer.displayName.isEmpty ? 'Nearby device' : peer.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          peer.encryptionReady
              ? 'Encrypted private chat ready'
              : canMessage
                  ? 'Private chat available'
                  : 'Finishing setup',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (unreadCount > 0) ...[
              _UnreadBadge(count: unreadCount),
              const SizedBox(width: 8),
            ],
            Icon(
              canMessage ? Icons.chevron_right_rounded : Icons.more_horiz_rounded,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnreadPrivateBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _UnreadPrivateBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                Icons.mark_chat_unread_outlined,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  count == 1
                      ? '1 unread private message'
                      : '$count unread private messages',
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: cs.error,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: cs.onError,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _RecentMessageTile extends StatelessWidget {
  final AirGridMessage message;

  const _RecentMessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPrivate = message.conversationType == 'private';
    final sender = message.isLocal ? 'You' : message.senderName;

    return ListTile(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: cs.outlineVariant.withAlpha(90)),
      ),
      leading: Icon(
        isPrivate ? Icons.lock_outline : Icons.forum_outlined,
        color: isPrivate ? cs.tertiary : cs.primary,
      ),
      title: Text(
        '$sender ${isPrivate ? 'privately' : 'in public'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        message.content,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ActionBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ActionBanner({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(message, style: TextStyle(color: cs.onErrorContainer)),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color? color;
  final VoidCallback? onTap;

  const _MetricChip({
    required this.icon,
    required this.label,
    required this.active,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chipColor = active ? (color ?? cs.primary) : cs.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? (color ?? cs.primary).withAlpha(24)
                : cs.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active
                  ? (color ?? cs.primary).withAlpha(90)
                  : cs.outlineVariant.withAlpha(80),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: chipColor),
              const SizedBox(width: 5),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: chipColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withAlpha(70)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: TextStyle(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
