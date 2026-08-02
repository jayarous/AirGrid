import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/features/settings/profile_avatar_catalog.dart';
import 'package:flutter/material.dart';

/// Shows the peer's key fingerprint so two people can compare it out-of-band.
///
/// This is the only way to confirm a key really belongs to who you think it
/// does: node IDs are not cryptographically bound to keys, so anything the
/// mesh tells you about a peer's identity is only as trustworthy as the mesh.
class _SafetyFingerprint extends StatelessWidget {
  final String publicKeyBase64;

  const _SafetyFingerprint({required this.publicKeyBase64});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: CryptoService.fingerprint(publicKeyBase64),
      builder: (context, snapshot) {
        final fingerprint = snapshot.data;
        if (fingerprint == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                'Safety number',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                fingerprint,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Compare this with the other person in real life. '
                'If it matches, your messages are going to them and nobody '
                'else. If it changes later, ask them why before trusting it.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );
  }
}

class PeerProfileSnapshot {
  final String displayName;
  final String nodeId;
  final String? profileIconId;
  final String? profileStatus;
  final bool isOnline;

  /// The peer's X25519 public key, used to show a verifiable fingerprint.
  ///
  /// Null when no key has been learned for this peer yet.
  final String? publicKeyBase64;

  const PeerProfileSnapshot({
    required this.displayName,
    required this.nodeId,
    this.profileIconId,
    this.profileStatus,
    required this.isOnline,
    this.publicKeyBase64,
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
    // Scrollable: content is variable-length (status text, safety number) and
    // the sheet must survive short viewports and large font scales.
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
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
            if (profile.publicKeyBase64 != null) ...[
              const SizedBox(height: 16),
              _SafetyFingerprint(publicKeyBase64: profile.publicKeyBase64!),
            ],
          ],
        ),
      ),
    ),
  );
}
