import 'package:airgrid/core/validation.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/settings/profile_avatar_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _statusController;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  late String _selectedIconId;

  @override
  void initState() {
    super.initState();
    final identity = ref.read(localIdentityStoreProvider);
    _nameController = TextEditingController(text: identity.displayName ?? '');
    _statusController = TextEditingController(
      text: identity.profileStatus ?? '',
    );
    final initialId = identity.profileIconId;
    _selectedIconId = ProfileAvatarCatalog.containsId(initialId)
        ? initialId
        : ProfileAvatarCatalog.defaultId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _statusController.dispose();
    super.dispose();
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
      final oldName = identity.displayName?.trim() ?? '';
      final nextName = validation.sanitizedValue!;
      final nextStatus = _statusController.text;
      final oldIconId = identity.profileIconId;
      final oldStatus = identity.profileStatus ?? '';

      await identity.saveDisplayName(nextName);
      await identity.saveProfileIconId(_selectedIconId);
      await identity.saveProfileStatus(nextStatus);

      final shouldRestartMesh = oldName != nextName;
      final shouldReannounceProfile =
          oldIconId != _selectedIconId || oldStatus.trim() != nextStatus.trim();
      if (shouldRestartMesh) {
        final controller = ref.read(chatControllerProvider.notifier);
        final meshWasStarted = ref.read(chatControllerProvider).meshStarted;
        if (meshWasStarted) {
          await controller.stopMesh();
          await controller.startMesh();
        }
      } else if (shouldReannounceProfile) {
        await ref.read(chatControllerProvider.notifier).announceLocalProfile();
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedIcon = ProfileAvatarCatalog.iconFor(_selectedIconId);

    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save Profile'),
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.outlineVariant.withAlpha(80)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: cs.primaryContainer,
                    child: Icon(
                      selectedIcon,
                      size: 34,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Profile preview',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'This is how nearby peers identify you in AirGrid.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
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
            TextFormField(
              controller: _statusController,
              maxLength: 80,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Display status',
                helperText: 'Shown below your display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Choose your icon',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: ProfileAvatarCatalog.options.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemBuilder: (context, index) {
                final option = ProfileAvatarCatalog.options[index];
                final isSelected = option.id == _selectedIconId;
                return _IconOptionTile(
                  option: option,
                  isSelected: isSelected,
                  onTap: () => setState(() => _selectedIconId = option.id),
                );
              },
            ),
            const SizedBox(height: 76),
          ],
        ),
      ),
    );
  }
}

class _IconOptionTile extends StatelessWidget {
  final ProfileAvatarOption option;
  final bool isSelected;
  final VoidCallback onTap;

  const _IconOptionTile({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: isSelected ? cs.primaryContainer : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? cs.primary : cs.outlineVariant,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                option.icon,
                color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                option.label,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
