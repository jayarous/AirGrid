import 'dart:io';

void main() {
  final file = File('airgrid/lib/features/home/home_screen.dart');
  var code = file.readAsStringSync();

  final quickActionsOld = """
class _QuickActions extends StatelessWidget {
  final VoidCallback onOpenPublicChat;
  final VoidCallback onOpenNearby;
  final VoidCallback onOpenWalkie;

  const _QuickActions({
    required this.onOpenPublicChat,
    required this.onOpenNearby,
    required this.onOpenWalkie,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onOpenPublicChat,
            icon: const Icon(Icons.forum_rounded),
            label: const Text('Public'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onOpenNearby,
            icon: const Icon(Icons.radar_rounded),
            label: const Text('Nearby'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onOpenWalkie,
            icon: const Icon(Icons.keyboard_voice_rounded),
            label: const Text('Walkie'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
""";

  final quickActionsNew = """
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
""";

  code = code.replaceAll(quickActionsOld, quickActionsNew);

  final peerTileOld = """
class _PeerTile extends StatelessWidget {
  final MeshPeer peer;
  final int unreadCount;
  final VoidCallback? onTap;

  const _PeerTile({
    required this.peer,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canMessage = peer.nodeId != null;

    return ListTile(
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: cs.outlineVariant.withAlpha(90)),
      ),
      leading: CircleAvatar(
        backgroundColor: canMessage
            ? cs.primaryContainer
            : cs.surfaceContainerHighest,
        child: Icon(
          canMessage ? Icons.person : Icons.sync,
          color: canMessage ? cs.onPrimaryContainer : cs.onSurfaceVariant,
        ),
      ),
      title: Text(
        peer.displayName.isEmpty ? 'Nearby device' : peer.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        peer.encryptionReady
            ? 'Encrypted private chat ready'
            : canMessage
            ? 'Private chat available'
            : 'Finishing setup',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unreadCount > 0) ...[
            _UnreadBadge(count: unreadCount),
            const SizedBox(width: 8),
          ],
          Icon(
            canMessage ? Icons.chevron_right : Icons.more_horiz,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
""";

  final peerTileNew = """
class _PeerTile extends StatelessWidget {
  final MeshPeer peer;
  final int unreadCount;
  final VoidCallback? onTap;

  const _PeerTile({
    required this.peer,
    required this.unreadCount,
    required this.onTap,
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
""";

  code = code.replaceAll(peerTileOld, peerTileNew);

  file.writeAsStringSync(code);
}
