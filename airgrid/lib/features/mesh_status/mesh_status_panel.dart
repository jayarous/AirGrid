import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Collapsible panel showing live mesh controls and diagnostics.
class MeshStatusPanel extends ConsumerWidget {
  const MeshStatusPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(chatControllerProvider.select((s) => s.peers));
    final isAdvertising = ref.watch(
      chatControllerProvider.select((s) => s.isAdvertising),
    );
    final isDiscovering = ref.watch(
      chatControllerProvider.select((s) => s.isDiscovering),
    );
    final playServicesAvailable = ref.watch(
      chatControllerProvider.select((s) => s.playServicesAvailable),
    );
    final meshStarted = ref.watch(
      chatControllerProvider.select((s) => s.meshStarted),
    );
    final isMeshStarting = ref.watch(
      chatControllerProvider.select((s) => s.isMeshStarting),
    );
    final lastEvent = ref.watch(
      chatControllerProvider.select((s) => s.lastEvent),
    );

    final cs = Theme.of(context).colorScheme;
    final controlsEnabled =
        playServicesAvailable && meshStarted && !isMeshStarting;
    final meshOnline = playServicesAvailable && meshStarted;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withAlpha(120)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(10),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mesh status',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusChip(
                icon: Icons.people_rounded,
                label: '${peers.length} peer${peers.length == 1 ? '' : 's'}',
                active: peers.isNotEmpty,
                color: Colors.teal,
              ),
              _StatusChip(
                icon: Icons.wifi_tethering_rounded,
                label: meshOnline ? 'Available' : 'Offline',
                active: playServicesAvailable && isAdvertising,
                color: Colors.green,
                isInteractive: true,
                onTap: controlsEnabled
                    ? () => ref
                          .read(chatControllerProvider.notifier)
                          .setAdvertisingEnabled(!isAdvertising)
                    : null,
              ),
              _StatusChip(
                icon: Icons.radar_rounded,
                label: meshOnline ? 'Scanning' : 'Idle',
                active: playServicesAvailable && isDiscovering,
                color: Colors.orange,
                isInteractive: true,
                onTap: controlsEnabled
                    ? () => ref
                          .read(chatControllerProvider.notifier)
                          .setDiscoveryEnabled(!isDiscovering)
                    : null,
              ),
            ],
          ),
          if (meshOnline && (isAdvertising || isDiscovering)) ...[
            const SizedBox(height: 8),
            if (isDiscovering)
              Text(
                'Looking for nearby AirGrid users',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            if (isAdvertising)
              Text(
                'Others AirGrid users nearby can find you',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
          ] else if (!controlsEnabled) ...[
            const SizedBox(height: 8),
            Text(
              'Mesh controls are unavailable right now',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          if (peers.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Connected: ${peers.map((p) => p.displayName.isNotEmpty ? p.displayName : p.endpointId.substring(0, 6)).join(', ')}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (lastEvent != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.terminal_rounded, size: 12, color: cs.outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    lastEvent,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color color;
  final bool isInteractive;
  final VoidCallback? onTap;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.color,
    this.isInteractive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chipColor = active ? color : cs.outline;
    final interactive = isInteractive && onTap != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: interactive ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? color.withAlpha(25)
                : cs.surfaceContainerHighest.withAlpha(120),
            border: Border.all(
              color: active ? color.withAlpha(100) : cs.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active &&
                  (icon == Icons.radar_rounded ||
                      icon == Icons.wifi_tethering_rounded))
                _PulsingDot(color: color)
              else
                Icon(icon, size: 14, color: chipColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: chipColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 12 * _controller.value,
                height: 12 * _controller.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 1 - _controller.value),
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
