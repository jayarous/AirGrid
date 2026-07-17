import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/battery_optimization_bridge.dart';
import 'package:airgrid/core/help_provider.dart';
import 'package:airgrid/core/help_target.dart';
import 'package:airgrid/core/logger.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/nearby/nearby_preferences.dart';
import 'package:airgrid/features/settings/profile_avatar_catalog.dart';
import 'package:airgrid/features/walkie/public_walkie_status_icon.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  final bool focusPermissions;

  const SettingsScreen({super.key, this.focusPermissions = false});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _permissionsKey = GlobalKey();
  bool _requestingPermissions = false;
  double _smoothingAlpha = nearbyDefaultSmoothingAlpha;
  SharedPreferences? _prefs;
  late Future<MeshPermissionsSnapshot> _permissionsFuture;
  late Future<PlayServicesStatus> _playServicesFuture;
  late Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _permissionsFuture = _loadPermissions();
    _playServicesFuture = _loadPlayServices();
    _packageInfoFuture = PackageInfo.fromPlatform();
    if (widget.focusPermissions) {
      _schedulePermissionsFocus();
    }
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        _smoothingAlpha = readNearbySmoothingAlpha(prefs);
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  void _schedulePermissionsFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToPermissions();
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _scrollToPermissions();
      });
    });
  }

  void _scrollToPermissions() {
    final context = _permissionsKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }
    setState(() {
      _permissionsFuture = _loadPermissions();
      _playServicesFuture = _loadPlayServices();
    });
  }

  Future<MeshPermissionsSnapshot> _loadPermissions() {
    return ref.read(meshPermissionsProvider).checkStatuses();
  }

  Future<PlayServicesStatus> _loadPlayServices() {
    return ref.read(playServicesProvider).checkAvailability();
  }

  void _showPrivacyModeDialog(
    BuildContext context,
    WidgetRef ref,
    PrivacyMode current,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        PrivacyMode selected = current;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Nearby Visibility'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: PrivacyMode.values.map((mode) {
                    return ChoiceChip(
                      label: Text(mode.label),
                      selected: selected == mode,
                      onSelected: (isSelected) {
                        if (isSelected) {
                          setState(() => selected = mode);
                        }
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                Text(selected.description),
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
                      .setPrivacyMode(selected);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _requestPermissions() async {
    setState(() => _requestingPermissions = true);
    try {
      final snapshot = await ref
          .read(meshPermissionsProvider)
          .requestMeshPermissions();
      if (!mounted) return;
      setState(() {
        _permissionsFuture = Future.value(snapshot);
      });
    } finally {
      if (mounted) {
        setState(() => _requestingPermissions = false);
      }
    }
  }

  Future<void> _requestIgnoreBatteryOptimizations() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await Permission.ignoreBatteryOptimizations.request();

    if (!mounted) return;
    setState(() {
      _permissionsFuture = _loadPermissions();
    });
  }

  Future<void> _openSystemBatteryOptimizationSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await BatteryOptimizationBridge.openSystemBatteryOptimizationSettings();
  }

  Future<void> _resolvePlayServices(PlayServicesStatus status) async {
    await ref.read(playServicesProvider).resolve(status);
    if (!mounted) return;
    setState(() {
      _playServicesFuture = _loadPlayServices();
    });
  }

  Future<void> _setSmoothingAlpha(double value) async {
    final alpha = normalizeNearbySmoothingAlpha(value);
    setState(() => _smoothingAlpha = alpha);
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setDouble(nearbySmoothingAlphaPrefKey, alpha);
  }

  Future<void> _clearAllChats() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all chats?'),
        content: const Text(
          'This will permanently remove all local chat history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(chatControllerProvider.notifier).clearAllChats();
    }
  }

  Future<void> _shareDiagnostics() async {
    final info = await _packageInfoFuture;
    final permissions = await _loadPermissions();
    final playServices = await _loadPlayServices();
    final state = ref.read(chatControllerProvider);
    final meshPermissions = ref.read(meshPermissionsProvider);
    final nativePermissions = await meshPermissions
        .androidRuntimePermissionStatuses();
    final lines = <String>[
      'AirGrid diagnostics',
      'Generated: ${DateTime.now().toIso8601String()}',
      'App: ${info.appName} ${info.version}+${info.buildNumber}',
      'Platform: ${defaultTargetPlatform.name}',
      '',
      'Mesh',
      'started=${state.meshStarted}',
      'starting=${state.isMeshStarting}',
      'advertising=${state.isAdvertising}',
      'discovering=${state.isDiscovering}',
      'peerCount=${state.peers.length}',
      'lastEvent=${state.lastEvent ?? 'none'}',
      '',
      'Google Play Services',
      'available=${playServices.available}',
      'code=${playServices.code}',
      'canResolve=${playServices.canResolve}',
      'message=${playServices.displayMessage}',
      '',
      'Permissions',
      for (final permission in MeshPermissions.allPermissions)
        '${meshPermissions.labelFor(permission)}=${permissions[permission]?.name ?? 'unknown'}',
      if (nativePermissions.isNotEmpty) ...[
        '',
        'Android permission check',
        for (final entry in nativePermissions.entries)
          '${entry.key}=${entry.value}',
      ],
      '',
      'Recent AirGrid logs',
      ...AirGridLogger.recentEntries(),
    ];
    await Share.share(lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(localIdentityStoreProvider);
    final state = ref.watch(chatControllerProvider);
    final cs = Theme.of(context).colorScheme;
    final displayName = identity.displayName?.trim();
    final blockedContacts = state.knownContacts
        .where((c) => c.isBlocked)
        .toList();
    final meshStatus = state.isMeshStarting
        ? _StatusSpec('Starting', Colors.orange, Icons.sync_rounded)
        : state.meshStarted
        ? _StatusSpec('Online', Colors.green, Icons.hub_rounded)
        : _StatusSpec('Offline', cs.outline, Icons.hub_outlined);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final helpMode = ref.watch(helpModeProvider);
              return IconButton(
                icon: Icon(helpMode ? Icons.help : Icons.help_outline),
                tooltip: helpMode ? 'Exit help mode' : 'Help',
                onPressed: () =>
                    ref.read(helpModeProvider.notifier).state = !helpMode,
              );
            },
          ),
          const PublicWalkieStatusIcon(),
        ],
      ),
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _ProfileCard(
            displayName: displayName == null || displayName.isEmpty
                ? 'Set your profile'
                : displayName,
            subtitle: identity.profileStatus?.trim().isNotEmpty == true
                ? identity.profileStatus!.trim()
                : 'Display name and icon',
            icon: ProfileAvatarCatalog.iconFor(identity.profileIconId),
            isOnline: state.meshStarted,
            onTap: () async {
              await Navigator.of(context).pushNamed(AppRouter.profileEdit);
              if (!mounted) return;
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Connection',
            children: [
              _SettingsRow(
                icon: meshStatus.icon,
                iconColor: meshStatus.color,
                title: 'Mesh status',
                subtitle: _meshSubtitle(state),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusChip(
                      label: meshStatus.label,
                      color: meshStatus.color,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Stop mesh now',
                      onPressed: state.meshStarted && !state.isMeshStarting
                          ? () {
                              unawaited(
                                ref
                                    .read(chatControllerProvider.notifier)
                                    .stopMesh(),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.power_settings_new),
                    ),
                  ],
                ),
              ),
              HelpTarget(
                title: 'Available',
                description:
                    'When enabled, your device is visible to others scanning nearby. '
                    'Turn off to become hidden from new discovery.',
                child: _SettingsSwitchRow(
                  icon: Icons.wifi_tethering_rounded,
                  iconColor: state.isAdvertising ? Colors.green : cs.outline,
                  title: 'Available',
                  subtitle: state.isAdvertising
                      ? 'Others nearby can find you.'
                      : 'You are hidden from new nearby discovery.',
                  value: state.playServicesAvailable && state.isAdvertising,
                  onChanged:
                      state.playServicesAvailable &&
                          state.meshStarted &&
                          !state.isMeshStarting
                      ? (value) => ref
                            .read(chatControllerProvider.notifier)
                            .setAdvertisingEnabled(value)
                      : null,
                ),
              ),
              HelpTarget(
                title: 'Scanning',
                description:
                    'When enabled, AirGrid actively scans for nearby users. '
                    'Disable scanning to save battery if you don\'t need to discover '
                    'new peers right now.',
                child: _SettingsSwitchRow(
                  icon: Icons.radar_rounded,
                  iconColor: state.isDiscovering ? Colors.orange : cs.outline,
                  title: 'Scanning',
                  subtitle: state.isDiscovering
                      ? 'Looking for nearby AirGrid users.'
                      : 'Not looking for new nearby users.',
                  value: state.playServicesAvailable && state.isDiscovering,
                  onChanged:
                      state.playServicesAvailable &&
                          state.meshStarted &&
                          !state.isMeshStarting
                      ? (value) => ref
                            .read(chatControllerProvider.notifier)
                            .setDiscoveryEnabled(value)
                      : null,
                ),
              ),
              _SmoothingRow(
                value: _smoothingAlpha,
                onChanged: _setSmoothingAlpha,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Battery & Device Access',
            children: [
              HelpTarget(
                title: 'Battery Saver',
                description:
                    'When on, AirGrid stops scanning and location sharing in the '
                    'background to save battery. You may miss messages until you '
                    'reopen the app. Turn off for continuous background mesh activity.',
                child: _SettingsSwitchRow(
                  icon: Icons.battery_saver_outlined,
                  title: 'AirGrid battery saver',
                  subtitle: state.batteryOptimizationEnabled
                      ? 'On: AirGrid stops scanning and sharing location in the background to save battery. You may miss nearby messages until you reopen the app.'
                      : 'Off: AirGrid may continue scanning in the background using Bluetooth and Wi-Fi. This can use more battery and may still be limited by Android.',
                  value: state.batteryOptimizationEnabled,
                  onChanged: (value) => ref
                      .read(chatControllerProvider.notifier)
                      .setBatteryOptimizationEnabled(value),
                ),
              ),
              if (defaultTargetPlatform == TargetPlatform.android)
                FutureBuilder<MeshPermissionsSnapshot>(
                  future: _permissionsFuture,
                  builder: (context, snapshot) {
                    final granted =
                        snapshot.data?.isGranted(
                          Permission.ignoreBatteryOptimizations,
                        ) ??
                        false;
                    final color = granted ? Colors.green : Colors.orange;
                    return _SettingsRow(
                      icon: granted
                          ? Icons.battery_charging_full
                          : Icons.battery_alert,
                      iconColor: color,
                      title: 'System battery exemption',
                      subtitle: granted
                          ? 'Android is less likely to stop AirGrid in background.'
                          : 'Android may pause background mesh activity.',
                      trailing: TextButton(
                        onPressed: granted
                            ? _openSystemBatteryOptimizationSettings
                            : _requestIgnoreBatteryOptimizations,
                        child: Text(granted ? 'Review' : 'Request'),
                      ),
                    );
                  },
                ),
              FutureBuilder<PlayServicesStatus>(
                future: _playServicesFuture,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const _LoadingRow(label: 'Google Play Services');
                  }
                  final status = snapshot.data!;
                  return _PlayServicesTile(
                    status: status,
                    onResolve: status.canResolve
                        ? () => _resolvePlayServices(status)
                        : null,
                  );
                },
              ),
              FutureBuilder<MeshPermissionsSnapshot>(
                key: _permissionsKey,
                future: _permissionsFuture,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const _LoadingRow(label: 'Permissions');
                  }
                  return _PermissionsPanel(
                    snapshot: snapshot.data!,
                    requestingPermissions: _requestingPermissions,
                    onRequestPermissions: _requestPermissions,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Privacy & Safety',
            children: [
              _SettingsRow(
                icon: Icons.visibility_outlined,
                title: 'Nearby Visibility',
                subtitle: state.privacyMode.label,
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showPrivacyModeDialog(context, ref, state.privacyMode),
              ),
              _SettingsRow(
                icon: Icons.verified_outlined,
                title: 'Invited Friends',
                subtitle: state.trustedNodeIds.isEmpty
                    ? 'No invited friends yet'
                    : '${state.trustedNodeIds.length} invited',
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context).pushNamed(AppRouter.trustedContacts),
              ),
              _SettingsRow(
                icon: Icons.flag_outlined,
                title: 'Safety Reports',
                subtitle: 'Review reports saved on this device',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(AppRouter.reports),
              ),
              _SettingsRow(
                icon: Icons.gavel_outlined,
                title: 'Terms & Safety',
                subtitle: 'Review disclaimers and user responsibilities',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(AppRouter.legal),
              ),
              if (blockedContacts.isEmpty)
                const _SettingsRow(
                  icon: Icons.block_outlined,
                  title: 'Blocked users',
                  subtitle: 'No blocked users',
                )
              else
                ...blockedContacts.map((contact) {
                  return _SettingsRow(
                    icon: Icons.block_outlined,
                    title: contact.displayName,
                    subtitle: 'Blocked user',
                    trailing: TextButton(
                      onPressed: () async {
                        await ref
                            .read(chatControllerProvider.notifier)
                            .unblockUser(contact.nodeId);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Unblocked'),
                            duration: Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: const Text('Unblock'),
                    ),
                  );
                }),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Data & Diagnostics',
            children: [
              _SettingsRow(
                icon: Icons.delete_forever,
                iconColor: cs.error,
                title: 'Clear all chats',
                subtitle: 'Remove all local chat history',
                trailing: TextButton(
                  onPressed: _clearAllChats,
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  child: const Text('Clear'),
                ),
                onTap: _clearAllChats,
              ),
              _SettingsRow(
                icon: Icons.fingerprint,
                title: 'Node ID',
                subtitle: identity.nodeId,
                monospaceSubtitle: true,
              ),
              _SettingsRow(
                icon: Icons.bug_report_outlined,
                title: 'Report a problem',
                subtitle:
                    'Share app, mesh, permission, Play Services, and recent log details',
                trailing: const Icon(Icons.ios_share_outlined),
                onTap: _shareDiagnostics,
              ),
            ],
          ),
          FutureBuilder<PackageInfo>(
            future: _packageInfoFuture,
            builder: (context, snapshot) {
              final info = snapshot.data;
              final versionLabel =
                  snapshot.connectionState == ConnectionState.waiting
                  ? 'App version loading...'
                  : snapshot.hasError || info == null
                  ? 'App version unavailable'
                  : 'App version ${info.version}+${info.buildNumber}';
              return Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        versionLabel,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: cs.outline),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Latest update: keyboard stability and chat input improvements.',
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: cs.outline),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

String _meshSubtitle(dynamic state) {
  if (state.isMeshStarting) return 'Starting the local mesh.';
  if (!state.playServicesAvailable) {
    return 'Nearby is unavailable on this device.';
  }
  if (!state.meshStarted &&
      ((state.lastEvent ?? '').startsWith('Mesh startup failed:') ||
          (state.lastEvent ?? '').startsWith('Transport error:'))) {
    return 'Nearby transport could not start.';
  }
  if (!state.meshStarted) return 'Mesh is off.';
  if (state.peers.isEmpty) return 'Broadcasting and scanning nearby.';
  return 'Connected to ${state.peers.length} nearby peer${state.peers.length == 1 ? '' : 's'}.';
}

class _StatusSpec {
  final String label;
  final Color color;
  final IconData icon;

  const _StatusSpec(this.label, this.color, this.icon);
}

class _ProfileCard extends StatelessWidget {
  final String displayName;
  final String subtitle;
  final IconData icon;
  final bool isOnline;
  final VoidCallback onTap;

  const _ProfileCard({
    required this.displayName,
    required this.subtitle,
    required this.icon,
    required this.isOnline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ProfileAvatarBadge(
                icon: icon,
                isOnline: isOnline,
                radius: 28,
                backgroundColor: cs.surface,
                iconColor: cs.primary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onPrimaryContainer.withAlpha(190),
                      ),
                    ),
                  ],
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

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant.withAlpha(80)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool monospaceSubtitle;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.monospaceSubtitle = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: _IconWell(icon: icon, color: iconColor),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
        subtitle,
        maxLines: monospaceSubtitle ? 3 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: cs.onSurfaceVariant,
          fontFamily: monospaceSubtitle ? 'monospace' : null,
          fontSize: monospaceSubtitle ? 12 : null,
        ),
      ),
      trailing: trailing,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SettingsSwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
      secondary: _IconWell(icon: icon, color: iconColor),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant)),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SmoothingRow extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _SmoothingRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconWell(icon: Icons.explore_outlined),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Heading smoothing',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    _StatusChip(
                      label: value.toStringAsFixed(2),
                      color: cs.primary,
                    ),
                  ],
                ),
                Text(
                  'Controls how quickly the nearby radar heading reacts.',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                Slider(
                  value: value,
                  min: nearbyMinSmoothingAlpha,
                  max: nearbyMaxSmoothingAlpha,
                  divisions: 13,
                  label: value.toStringAsFixed(2),
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionsPanel extends ConsumerWidget {
  final MeshPermissionsSnapshot snapshot;
  final bool requestingPermissions;
  final VoidCallback onRequestPermissions;

  const _PermissionsPanel({
    required this.snapshot,
    required this.requestingPermissions,
    required this.onRequestPermissions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.read(meshPermissionsProvider);
    final rows = <Permission>[
      ...MeshPermissions.criticalPermissions,
      ...MeshPermissions.optionalPermissions,
    ];
    final grantedCount = rows.where(snapshot.isGranted).length;
    final cs = Theme.of(context).colorScheme;
    final summaryColor = grantedCount == rows.length
        ? Colors.green
        : Colors.orange;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconWell(
                icon: grantedCount == rows.length
                    ? Icons.verified_user_outlined
                    : Icons.security,
                color: summaryColor,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Permissions',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'Bluetooth, Wi-Fi, location, and notifications access.',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              _StatusChip(
                label: '$grantedCount of ${rows.length}',
                color: summaryColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...rows.map((permission) {
            final granted = snapshot.isGranted(permission);
            final isOptional = MeshPermissions.optionalPermissions.contains(
              permission,
            );
            final permanentlyDenied =
                snapshot[permission]?.isPermanentlyDenied == true;
            final color = granted
                ? Colors.green
                : permanentlyDenied
                ? Colors.red
                : isOptional
                ? Colors.orange
                : Colors.red;
            final icon = granted
                ? Icons.check_circle
                : permanentlyDenied
                ? Icons.block
                : Icons.info_outline;

            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: color),
              title: Text(permissions.labelFor(permission)),
              subtitle: Text(permissions.descriptionFor(permission)),
              trailing: Text(
                granted ? 'Granted' : 'Needed',
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            );
          }),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: requestingPermissions
                      ? null
                      : onRequestPermissions,
                  icon: requestingPermissions
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.security),
                  label: const Text('Request permissions'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: openAppSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('System settings'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayServicesTile extends StatelessWidget {
  final PlayServicesStatus status;
  final VoidCallback? onResolve;

  const _PlayServicesTile({required this.status, required this.onResolve});

  @override
  Widget build(BuildContext context) {
    final color = status.available
        ? Colors.green
        : Theme.of(context).colorScheme.error;
    return _SettingsRow(
      icon: status.available ? Icons.check_circle : Icons.error_outline,
      iconColor: color,
      title: 'Google Play Services',
      subtitle: status.available ? status.message : status.displayMessage,
      trailing: onResolve == null
          ? _StatusChip(
              label: status.available ? 'Available' : 'Unsupported',
              color: color,
            )
          : TextButton(onPressed: onResolve, child: const Text('Fix')),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  final String label;

  const _LoadingRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: const SizedBox(
        width: 36,
        height: 36,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      title: Text(label),
      subtitle: const Text('Checking status...'),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _IconWell extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const _IconWell({required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = color ?? cs.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconColor.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: iconColor),
    );
  }
}
