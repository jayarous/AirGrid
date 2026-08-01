import 'package:airgrid/features/settings/profile_avatar_catalog.dart';
import 'package:flutter/material.dart';

class PeerProfileSnapshot {
  final String displayName;
  final String nodeId;
  final String? profileIconId;
  final String? profileStatus;
  final bool isOnline;

  const PeerProfileSnapshot({
    required this.displayName,
    required this.nodeId,
    this.profileIconId,
    this.profileStatus,
    required this.isOnline,
  });
}

Future<void> showPeerProfileSheet(
  BuildContext context,
  PeerProfileSnapshot profile,
) async {
  final cs = Theme.of(context).colorScheme;
  final icon = ProfileAvatarCatalog.iconFor(profile.profileIconId);
  final status = profile.profileStatus?.trim();

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProfileAvatarBadge(
              icon: icon,
              isOnline: profile.isOnline,
              radius: 30,
              backgroundColor: cs.primaryContainer,
              iconColor: cs.onPrimaryContainer,
            ),
            const SizedBox(height: 14),
            Text(
              profile.displayName,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (status != null && status.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                status,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              profile.isOnline ? 'Online' : 'Offline',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: profile.isOnline ? Colors.green : Colors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              profile.nodeId,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.outline,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}
