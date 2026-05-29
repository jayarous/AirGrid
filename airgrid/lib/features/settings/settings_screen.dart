import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/battery_optimization_bridge.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/core/validation.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/nearby/nearby_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _nameController;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
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
    final identity = ref.read(localIdentityStoreProvider);
    _nameController = TextEditingController(text: identity.displayName ?? '');
    _permissionsFuture = _loadPermissions();
    _playServicesFuture = _loadPlayServices();
    _packageInfoFuture = PackageInfo.fromPlatform();
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
    _nameController.dispose();
    super.dispose();
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
              children: PrivacyMode.values.map((mode) {
                return RadioListTile<PrivacyMode>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(mode.label),
                  subtitle: Text(mode.description),
                  value: mode,
                  groupValue: selected,
                  onChanged: (m) {
                    if (m != null) setState(() => selected = m);
                  },
                );
              }).toList(),
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

  Future<PlayServicesStatus> _loadPlayServices() {
    return ref.read(playServicesProvider).checkAvailability();
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text;
    final validation = DisplayNameValidator.validateLocal(name);

    if (!validation.isValid) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validation.error!)));
      return;
    }

    setState(() => _saving = true);
    try {
      final identity = ref.read(localIdentityStoreProvider);
      // Save the sanitized value
      await identity.saveDisplayName(validation.sanitizedValue!);

      // Restart mesh with the new name if it was already running.
      final controller = ref.read(chatControllerProvider.notifier);
      final meshWasStarted = ref.read(chatControllerProvider).meshStarted;
      if (meshWasStarted) {
        await controller.stopMesh();
        await controller.startMesh();
      }

      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final identity = ref.read(localIdentityStoreProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            TextFormField(
              controller: _nameController,
              maxLength: 40,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Display name',
                helperText: 'Shown to nearby peers',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Name cannot be empty';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const Divider(height: 32),
            Text(
              'Nearby radar',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Heading smoothing'),
              subtitle: Slider(
                value: _smoothingAlpha,
                min: nearbyMinSmoothingAlpha,
                max: nearbyMaxSmoothingAlpha,
                divisions: 13,
                label: _smoothingAlpha.toStringAsFixed(2),
                onChanged: _setSmoothingAlpha,
              ),
              trailing: SizedBox(
                width: 44,
                child: Text(
                  _smoothingAlpha.toStringAsFixed(2),
                  textAlign: TextAlign.end,
                ),
              ),
            ),
            const Divider(height: 32),
            Text(
              'Battery Optimization',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Builder(
              builder: (ctx) {
                final batteryOptimizationEnabled = ref.watch(
                  chatControllerProvider.select(
                    (s) => s.batteryOptimizationEnabled,
                  ),
                );
                final meshStarted = ref.watch(
                  chatControllerProvider.select((s) => s.meshStarted),
                );
                final isMeshStarting = ref.watch(
                  chatControllerProvider.select((s) => s.isMeshStarting),
                );
                final playServicesAvailable = ref.watch(
                  chatControllerProvider.select((s) => s.playServicesAvailable),
                );
                final isAdvertising = ref.watch(
                  chatControllerProvider.select((s) => s.isAdvertising),
                );
                final isDiscovering = ref.watch(
                  chatControllerProvider.select((s) => s.isDiscovering),
                );
                final status = isMeshStarting
                    ? 'Starting'
                    : meshStarted
                    ? 'On'
                    : 'Off';
                final statusColor = isMeshStarting
                    ? Colors.orange
                    : meshStarted
                    ? Colors.green
                    : Theme.of(ctx).colorScheme.outline;

                return Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.battery_saver_outlined),
                      title: const Text('Battery Optimization'),
                      subtitle: Text(
                        batteryOptimizationEnabled
                            ? 'On: AirGrid stops scanning and sharing location in the background to save battery. You may miss nearby messages until you reopen the app.'
                            : 'Off: AirGrid may continue scanning in the background using Bluetooth and Wi-Fi. This can use more battery and may still be limited by Android.',
                      ),
                      value: batteryOptimizationEnabled,
                      onChanged: (value) => ref
                          .read(chatControllerProvider.notifier)
                          .setBatteryOptimizationEnabled(value),
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
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              granted
                                  ? Icons.battery_charging_full
                                  : Icons.battery_alert,
                              color: color,
                            ),
                            title: const Text('System battery exemption'),
                            subtitle: Text(
                              granted
                                  ? 'Enabled: Android is less likely to stop AirGrid in background.'
                                  : 'Disabled: Android may pause background mesh activity.',
                            ),
                            trailing: TextButton(
                              onPressed: granted
                                  ? _openSystemBatteryOptimizationSettings
                                  : _requestIgnoreBatteryOptimizations,
                              child: Text(
                                granted ? 'Review' : 'Request',
                                style: TextStyle(color: color),
                              ),
                            ),
                          );
                        },
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        meshStarted ? Icons.hub : Icons.hub_outlined,
                        color: statusColor,
                      ),
                      title: const Text('Mesh status'),
                      subtitle: Text(status),
                      trailing: TextButton.icon(
                        onPressed: meshStarted && !isMeshStarting
                            ? () {
                                unawaited(
                                  ref
                                      .read(chatControllerProvider.notifier)
                                      .stopMesh(),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.power_settings_new),
                        label: const Text('Stop mesh now'),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        Icons.wifi_tethering_rounded,
                        color: isAdvertising
                            ? Colors.green
                            : Theme.of(ctx).colorScheme.outline,
                      ),
                      title: const Text('Available'),
                      subtitle: Text(
                        isAdvertising
                            ? 'Others nearby can find you.'
                            : 'You are hidden from new nearby discovery.',
                      ),
                      value: playServicesAvailable && isAdvertising,
                      onChanged:
                          playServicesAvailable &&
                              meshStarted &&
                              !isMeshStarting
                          ? (value) => ref
                                .read(chatControllerProvider.notifier)
                                .setAdvertisingEnabled(value)
                          : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        Icons.radar_rounded,
                        color: isDiscovering
                            ? Colors.orange
                            : Theme.of(ctx).colorScheme.outline,
                      ),
                      title: const Text('Scanning'),
                      subtitle: Text(
                        isDiscovering
                            ? 'Looking for nearby AirGrid users.'
                            : 'Not looking for new nearby users.',
                      ),
                      value: playServicesAvailable && isDiscovering,
                      onChanged:
                          playServicesAvailable &&
                              meshStarted &&
                              !isMeshStarting
                          ? (value) => ref
                                .read(chatControllerProvider.notifier)
                                .setDiscoveryEnabled(value)
                          : null,
                    ),
                  ],
                );
              },
            ),
            const Divider(height: 32),
            Text(
              'Platform support',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            FutureBuilder<PlayServicesStatus>(
              future: _playServicesFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  );
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
            const Divider(height: 32),
            Text('Permissions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder<MeshPermissionsSnapshot>(
              future: _permissionsFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final permissions = ref.read(meshPermissionsProvider);
                final permissionsSnapshot = snapshot.data!;
                final rows = <Permission>[
                  ...MeshPermissions.criticalPermissions,
                  ...MeshPermissions.optionalPermissions,
                ];

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...rows.map((permission) {
                      final granted = permissionsSnapshot.isGranted(permission);
                      // Use Mesh Status color scheme: green = granted,
                      // orange = optional needed, red = mandatory needed / permanently denied.
                      final isOptional = MeshPermissions.optionalPermissions
                          .contains(permission);
                      final permanentlyDenied =
                          permissionsSnapshot[permission]
                              ?.isPermanentlyDenied ==
                          true;

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

                      final trailingText = granted ? 'Granted' : 'Needed';

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(icon, color: color),
                        title: Text(permissions.labelFor(permission)),
                        subtitle: Text(permissions.descriptionFor(permission)),
                        trailing: Text(
                          trailingText,
                          style: TextStyle(color: color),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    FutureBuilder<MeshPermissionsSnapshot>(
                      future: _permissionsFuture,
                      builder: (context, snapshot) {
                        // Always offer a shortcut to the system app settings
                        // so the user can revoke permissions if they want.
                        final showOpenSettings = true;

                        return Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _requestingPermissions
                                    ? null
                                    : _requestPermissions,
                                icon: _requestingPermissions
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.security),
                                label: const Text('Request permissions'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (showOpenSettings)
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: openAppSettings,
                                  icon: const Icon(Icons.settings),
                                  label: const Text('Open system settings'),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Clear all chats'),
              subtitle: const Text(
                'Remove all local chat history (destructive)',
              ),
              trailing: const Icon(Icons.delete_forever, color: Colors.red),
              onTap: () async {
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
                  setState(() => _saving = true);
                  try {
                    await ref
                        .read(chatControllerProvider.notifier)
                        .clearAllChats();
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                }
              },
            ),
            const Divider(height: 32),
            Text(
              'Safety & Privacy',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Builder(
              builder: (ctx) {
                final mode = ref.watch(
                  chatControllerProvider.select((s) => s.privacyMode),
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('Nearby Visibility'),
                  subtitle: Text(mode.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPrivacyModeDialog(ctx, ref, mode),
                );
              },
            ),
            Builder(
              builder: (ctx) {
                final trustedCount = ref.watch(
                  chatControllerProvider.select((s) => s.trustedNodeIds.length),
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_outlined),
                  title: const Text('Invited Friends'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (trustedCount > 0)
                        Text(
                          '$trustedCount',
                          style: Theme.of(ctx).textTheme.bodyMedium,
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () =>
                      Navigator.of(ctx).pushNamed(AppRouter.trustedContacts),
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Safety Reports'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed(AppRouter.reports),
            ),
            const Divider(height: 32),
            Text(
              'Blocked users',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final blockedContacts = ref
                    .watch(
                      chatControllerProvider.select((s) => s.knownContacts),
                    )
                    .where((c) => c.isBlocked)
                    .toList();
                if (blockedContacts.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No blocked users',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  );
                }
                return Column(
                  children: blockedContacts.map((contact) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(contact.displayName),
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
                  }).toList(),
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Node ID'),
              subtitle: Text(
                identity.nodeId,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 18),
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
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Center(
                    child: Text(
                      versionLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
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
    final cs = Theme.of(context).colorScheme;
    final color = status.available ? cs.primary : cs.error;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        status.available ? Icons.check_circle : Icons.error_outline,
        color: color,
      ),
      title: const Text('Google Play Services'),
      subtitle: Text(status.available ? status.message : status.displayMessage),
      trailing: onResolve == null
          ? Text(
              status.available ? 'Available' : 'Unsupported',
              style: TextStyle(color: color),
            )
          : TextButton(onPressed: onResolve, child: const Text('Fix')),
    );
  }
}
