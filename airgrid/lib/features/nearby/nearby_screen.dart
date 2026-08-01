import 'dart:async';
import 'dart:math' as math;

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/peer_location.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/nearby/nearby_preferences.dart';
import 'package:airgrid/features/profile/peer_profile_sheet.dart';
import 'package:airgrid/features/walkie/public_walkie_status_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NearbyScreen extends ConsumerWidget {
  const NearbyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final cs = Theme.of(context).colorScheme;
    final nearbyBlocked = !state.playServicesAvailable;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby'),
        actions: const [PublicWalkieStatusIcon()],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Online around you',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            nearbyBlocked
                ? state.playServicesMessage
                : state.peers.isEmpty
                ? 'Scanning for online AirGrid users.'
                : '${state.peers.length} online peer${state.peers.length == 1 ? '' : 's'} connected now.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          _NearbyRadar(
            peers: state.peers,
            localLocation: state.localLocation,
            peerLocations: state.peerLocations,
          ),
          const SizedBox(height: 16),
          _LocationSharingPanel(
            meshStarted: state.meshStarted,
            isSharing: state.isLocationSharing,
            status: state.locationStatus,
            onToggle: state.isLocationSharing
                ? ref.read(chatControllerProvider.notifier).stopLocationSharing
                : ref
                      .read(chatControllerProvider.notifier)
                      .startLocationSharing,
          ),
          const SizedBox(height: 8),
          _CompassPreferenceTile(),
          const SizedBox(height: 20),
          Text(
            'Online users',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (state.peers.isEmpty)
            _EmptyNearbyPanel(
              blocked: nearbyBlocked,
              message: nearbyBlocked
                  ? state.playServicesMessage
                  : 'No online users are connected yet.',
            )
          else
            ...state.peers.map(
              (peer) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _NearbyPeerTile(
                  peer: peer,
                  contactProfile: peer.nodeId == null
                      ? null
                      : state.knownContacts.cast<KnownContact?>().firstWhere(
                          (c) => c?.nodeId == peer.nodeId,
                          orElse: () => null,
                        ),
                  localLocation: state.localLocation,
                  peerLocation: peer.nodeId == null
                      ? null
                      : state.peerLocations[peer.nodeId],
                  onTap: peer.nodeId == null
                      ? null
                      : () {
                          ref
                              .read(chatControllerProvider.notifier)
                              .selectConversation(
                                PrivateConversation(
                                  peerNodeId: peer.nodeId!,
                                  peerName: peer.displayName,
                                ),
                              );
                          Navigator.of(context).pushNamed(AppRouter.chat);
                        },
                  onWalkie: peer.nodeId == null
                      ? null
                      : () {
                          ref
                              .read(chatControllerProvider.notifier)
                              .selectConversation(
                                PrivateConversation(
                                  peerNodeId: peer.nodeId!,
                                  peerName: peer.displayName,
                                ),
                              );
                          Navigator.of(context).pushNamed(AppRouter.walkie);
                        },
                  isTrusted:
                      peer.nodeId != null &&
                      state.trustedNodeIds.contains(peer.nodeId),
                  onTrust: peer.nodeId == null
                      ? null
                      : () => ref
                            .read(chatControllerProvider.notifier)
                            .trustContact(peer.nodeId!),
                  onUntrust: peer.nodeId == null
                      ? null
                      : () => ref
                            .read(chatControllerProvider.notifier)
                            .untrustContact(peer.nodeId!),
                  onReport: peer.nodeId == null
                      ? null
                      : () => _showReportUserDialog(
                          context,
                          ref,
                          peer.nodeId!,
                          peer.displayName,
                        ),
                  onBlock: peer.nodeId == null
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Block user?'),
                              content: const Text(
                                'You will no longer see messages or nearby updates '
                                'from this user. Existing chat history stays on this device.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('Block'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref
                                .read(chatControllerProvider.notifier)
                                .blockUser(peer.nodeId!);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('User blocked'),
                                duration: Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

void _showReportUserDialog(
  BuildContext context,
  WidgetRef ref,
  String reportedNodeId,
  String reportedDisplayName,
) {
  ReportReason selectedReason = ReportReason.spam;
  final notesController = TextEditingController();

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Report $reportedDisplayName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<ReportReason>(
              isExpanded: true,
              value: selectedReason,
              items: ReportReason.values
                  .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                  .toList(),
              onChanged: (r) {
                if (r != null) setState(() => selectedReason = r);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: notesController,
              decoration: const InputDecoration(
                labelText: 'Additional notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref
                  .read(chatControllerProvider.notifier)
                  .reportUser(
                    reportedNodeId: reportedNodeId,
                    reportedDisplayName: reportedDisplayName,
                    reason: selectedReason,
                    notes: notesController.text.trim().isEmpty
                        ? null
                        : notesController.text.trim(),
                  );
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Report submitted')));
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    ),
  );
}

class _NearbyRadar extends StatefulWidget {
  final List<MeshPeer> peers;
  final PeerLocation? localLocation;
  final Map<String, PeerLocation> peerLocations;

  const _NearbyRadar({
    required this.peers,
    required this.localLocation,
    required this.peerLocations,
  });

  @override
  State<_NearbyRadar> createState() => _NearbyRadarState();
}

class _NearbyRadarState extends State<_NearbyRadar> {
  StreamSubscription<CompassEvent>? _compassSub;
  double? _deviceHeading;
  double? _smoothedHeading;
  SharedPreferences? _prefs;

  double _alpha = nearbyDefaultSmoothingAlpha;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _prefs = p;
      setState(() {
        _alpha = readNearbySmoothingAlpha(p);
      });
    });
    _compassSub = FlutterCompass.events?.listen((ev) {
      setState(() {
        _deviceHeading = ev.heading; // may be null
        _updateSmoothed();
      });
    });
  }

  @override
  void didUpdateWidget(covariant _NearbyRadar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Local location may have changed; recompute smoothing source.
    _updateSmoothed();
  }

  void _updateSmoothed() {
    final prefs = _prefs;
    if (prefs != null) {
      _alpha = readNearbySmoothingAlpha(prefs);
    }
    final useDevice = prefs?.getBool(nearbyUseDeviceCompassPrefKey) ?? true;
    double newHeading;
    final locHeading = widget.localLocation?.headingDegrees;
    if (useDevice && _deviceHeading != null && !_deviceHeading!.isNaN) {
      newHeading = _deviceHeading!;
    } else if (locHeading != null && !locHeading.isNaN) {
      newHeading = locHeading;
    } else {
      newHeading = 0.0;
    }

    // Normalize to 0..360
    newHeading = (newHeading % 360 + 360) % 360;

    if (_smoothedHeading == null) {
      _smoothedHeading = newHeading;
      return;
    }

    // Smooth on circular angle domain.
    final old = _smoothedHeading!;
    final double delta = (newHeading - old + 540) % 360 - 180; // -180..180
    final smoothed = (old + _alpha * delta) % 360;
    _smoothedHeading = smoothed < 0 ? smoothed + 360 : smoothed;
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: CustomPaint(
          painter: _RadarPainter(
            peers: widget.peers,
            localLocation: widget.localLocation,
            peerLocations: widget.peerLocations,
            smoothedHeadingDegrees: _smoothedHeading ?? 0.0,
            primary: cs.primary,
            tertiary: cs.tertiary,
            outline: cs.outlineVariant,
            surface: cs.surface,
            onSurface: cs.onSurface,
            onSurfaceVariant: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final List<MeshPeer> peers;
  final PeerLocation? localLocation;
  final Map<String, PeerLocation> peerLocations;
  final Color primary;
  final Color tertiary;
  final Color outline;
  final Color surface;
  final Color onSurface;
  final Color onSurfaceVariant;

  final double smoothedHeadingDegrees;

  _RadarPainter({
    required this.peers,
    required this.localLocation,
    required this.peerLocations,
    required this.smoothedHeadingDegrees,
    required this.primary,
    required this.tertiary,
    required this.outline,
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 28;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline;
    final sweepPaint = Paint()
      ..shader = RadialGradient(
        colors: [primary.withAlpha(34), primary.withAlpha(0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline.withAlpha(130);

    canvas.drawCircle(center, radius, sweepPaint);
    for (final fraction in [0.34, 0.66, 1.0]) {
      canvas.drawCircle(center, radius * fraction, ringPaint);
    }
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      axisPaint,
    );

    // Use smoothed heading (device or shared) so compass labels and
    // peer placements rotate smoothly with device orientation.
    final headingDegrees = smoothedHeadingDegrees;
    double angleForBearing(double bearingDegrees) =>
        (bearingDegrees - headingDegrees - 90) * math.pi / 180;

    final labelDistance = radius + 14;
    _drawCompassLabel(
      canvas,
      'N',
      Offset(
        center.dx + math.cos(angleForBearing(0)) * labelDistance,
        center.dy + math.sin(angleForBearing(0)) * labelDistance,
      ),
    );
    _drawCompassLabel(
      canvas,
      'E',
      Offset(
        center.dx + math.cos(angleForBearing(90)) * labelDistance,
        center.dy + math.sin(angleForBearing(90)) * labelDistance,
      ),
    );
    _drawCompassLabel(
      canvas,
      'S',
      Offset(
        center.dx + math.cos(angleForBearing(180)) * labelDistance,
        center.dy + math.sin(angleForBearing(180)) * labelDistance,
      ),
    );
    _drawCompassLabel(
      canvas,
      'W',
      Offset(
        center.dx + math.cos(angleForBearing(270)) * labelDistance,
        center.dy + math.sin(angleForBearing(270)) * labelDistance,
      ),
    );

    final selfPaint = Paint()..color = primary;
    canvas.drawCircle(center, 12, selfPaint);
    canvas.drawCircle(center, 18, Paint()..color = primary.withAlpha(28));
    _drawCenteredText(canvas, 'You', center.translate(0, 28), onSurface, 12);

    final maxDistance = _maxVisibleDistanceMeters();
    for (var i = 0; i < peers.length; i++) {
      final peer = peers[i];
      final peerLocation = peer.nodeId == null
          ? null
          : peerLocations[peer.nodeId];
      final placement = _placementFor(peer, peerLocation, i, maxDistance);
      final angle = placement.$1;
      final distance = radius * placement.$2;
      final offset = Offset(
        center.dx + math.cos(angle) * distance,
        center.dy + math.sin(angle) * distance,
      );
      final peerPaint = Paint()
        ..color = peer.encryptionReady ? tertiary : primary;
      canvas.drawCircle(offset, 10, peerPaint);
      canvas.drawCircle(
        offset,
        16,
        Paint()..color = peerPaint.color.withAlpha(26),
      );
      _drawCenteredText(
        canvas,
        _initials(peer.displayName),
        offset,
        surface,
        11,
        fontWeight: FontWeight.w700,
      );
    }
  }

  double _maxVisibleDistanceMeters() {
    final local = localLocation;
    if (local == null) return 100;
    final distances = peerLocations.values
        .map(local.distanceMetersTo)
        .where((distance) => distance.isFinite && distance > 0)
        .toList();
    if (distances.isEmpty) return 100;
    return math.max(50, distances.reduce(math.max));
  }

  (double, double) _placementFor(
    MeshPeer peer,
    PeerLocation? peerLocation,
    int index,
    double maxDistance,
  ) {
    final local = localLocation;
    if (local != null && peerLocation != null) {
      final bearing = local.bearingDegreesTo(peerLocation);
      final distance = local.distanceMetersTo(peerLocation);
      final angle = (bearing - smoothedHeadingDegrees - 90) * math.pi / 180;
      return (angle, (distance / maxDistance).clamp(0.18, 0.94));
    }

    final seed = peer.endpointId.codeUnits.fold<int>(
      index + 17,
      (value, code) => (value * 31 + code) & 0x7fffffff,
    );
    final angle = (seed % 360) * math.pi / 180;
    final distance = 0.36 + ((seed ~/ 360) % 46) / 100;
    return (angle, distance);
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }

  void _drawCompassLabel(Canvas canvas, String text, Offset offset) {
    _drawCenteredText(canvas, text, offset, onSurfaceVariant, 11);
  }

  void _drawCenteredText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize, {
    FontWeight fontWeight = FontWeight.w500,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      offset.translate(-painter.width / 2, -painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.peers != peers ||
      oldDelegate.localLocation != localLocation ||
      oldDelegate.smoothedHeadingDegrees != smoothedHeadingDegrees ||
      oldDelegate.peerLocations != peerLocations ||
      oldDelegate.primary != primary ||
      oldDelegate.tertiary != tertiary ||
      oldDelegate.outline != outline;
}

// Small tile to persist user preference for using device compass
class _CompassPreferenceTile extends StatefulWidget {
  const _CompassPreferenceTile();

  @override
  State<_CompassPreferenceTile> createState() => _CompassPreferenceTileState();
}

class _CompassPreferenceTileState extends State<_CompassPreferenceTile> {
  bool _useDevice = true;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _prefs = p;
      setState(() {
        _useDevice = p.getBool(nearbyUseDeviceCompassPrefKey) ?? true;
      });
    });
  }

  void _toggle(bool v) async {
    setState(() => _useDevice = v);
    await (_prefs ??= await SharedPreferences.getInstance()).setBool(
      nearbyUseDeviceCompassPrefKey,
      v,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Use device compass'),
      subtitle: const Text(
        'Prefer device compass heading over shared heading.',
      ),
      value: _useDevice,
      onChanged: (v) => _toggle(v),
    );
  }
}

class _LocationSharingPanel extends StatelessWidget {
  final bool meshStarted;
  final bool isSharing;
  final String? status;
  final Future<void> Function() onToggle;

  const _LocationSharingPanel({
    required this.meshStarted,
    required this.isSharing,
    required this.status,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.location_on_outlined, color: cs.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSharing
                      ? 'Live location sharing on'
                      : 'Share live location',
                  style: TextStyle(
                    color: cs.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status ??
                      'Turn this on to show real distance and direction to peers who also share location.',
                  style: TextStyle(color: cs.onSecondaryContainer),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: isSharing,
            onChanged: meshStarted ? (_) => onToggle() : null,
          ),
        ],
      ),
    );
  }
}

class _NearbyPeerTile extends StatelessWidget {
  final MeshPeer peer;
  final KnownContact? contactProfile;
  final PeerLocation? localLocation;
  final PeerLocation? peerLocation;
  final VoidCallback? onTap;
  final VoidCallback? onWalkie;
  final bool isTrusted;
  final VoidCallback? onTrust;
  final VoidCallback? onUntrust;
  final VoidCallback? onBlock;
  final VoidCallback? onReport;

  const _NearbyPeerTile({
    required this.peer,
    this.contactProfile,
    required this.localLocation,
    required this.peerLocation,
    required this.onTap,
    this.onWalkie,
    this.isTrusted = false,
    this.onTrust,
    this.onUntrust,
    this.onBlock,
    this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connectedFor = DateTime.now().difference(peer.connectedAt);
    final locationText = _locationText();

    return ListTile(
      onTap: onTap,
      onLongPress: (onBlock != null || onTrust != null || onReport != null)
          ? () => _showPeerSheet(context)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: cs.outlineVariant),
      ),
      leading: CircleAvatar(
        backgroundColor: peer.encryptionReady
            ? cs.tertiaryContainer
            : cs.primaryContainer,
        child: Icon(
          peer.encryptionReady ? Icons.lock_outline : Icons.person_pin_circle,
          color: peer.encryptionReady
              ? cs.onTertiaryContainer
              : cs.onPrimaryContainer,
        ),
      ),
      title: Text(
        peer.displayName.isEmpty ? 'Nearby device' : peer.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        'Online for ${_formatDuration(connectedFor)} • $locationText',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        peer.nodeId == null ? Icons.more_horiz : Icons.chevron_right,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  void _showPeerSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (peer.nodeId != null)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('View profile'),
                onTap: () {
                  Navigator.pop(context);
                  final nodeId = peer.nodeId!;
                  showPeerProfileSheet(
                    context,
                    PeerProfileSnapshot(
                      displayName: peer.displayName,
                      nodeId: nodeId,
                      profileIconId: contactProfile?.profileIconId,
                      profileStatus: contactProfile?.profileStatus,
                      isOnline: true,
                    ),
                  );
                },
              ),
            if (isTrusted && onUntrust != null)
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: const Text('Remove from invited friends'),
                onTap: () {
                  Navigator.pop(context);
                  onUntrust!();
                },
              )
            else if (!isTrusted && onTrust != null)
              ListTile(
                leading: const Icon(Icons.verified),
                title: const Text('Add to invited friends'),
                onTap: () {
                  Navigator.pop(context);
                  onTrust!();
                },
              ),
            if (onReport != null)
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report user'),
                onTap: () {
                  Navigator.pop(context);
                  onReport!();
                },
              ),
            if (onWalkie != null)
              ListTile(
                leading: const Icon(Icons.keyboard_voice_rounded),
                title: const Text('Open walkie-talkie'),
                onTap: () {
                  Navigator.pop(context);
                  onWalkie!();
                },
              ),
            if (onBlock != null)
              ListTile(
                leading: const Icon(Icons.block, color: Colors.red),
                title: const Text(
                  'Block user',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(context);
                  onBlock!();
                },
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inMinutes < 1) return 'now';
    if (duration.inHours < 1) return '${duration.inMinutes}m';
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }

  String _locationText() {
    final local = localLocation;
    final peerLoc = peerLocation;
    if (local == null || peerLoc == null) return 'Distance unavailable';
    final distance = local.distanceMetersTo(peerLoc);
    final bearing = local.bearingDegreesTo(peerLoc);
    final direction = PeerLocation.cardinalDirection(bearing);
    return '${_formatDistance(distance)} $direction';
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
}

class _EmptyNearbyPanel extends StatelessWidget {
  final bool blocked;
  final String message;

  const _EmptyNearbyPanel({required this.blocked, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            blocked ? Icons.error_outline : Icons.travel_explore,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
