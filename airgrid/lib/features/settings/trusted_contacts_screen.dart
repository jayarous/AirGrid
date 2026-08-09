import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/paywall/plus_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Displays all contacts the user has trusted, with a button to remove trust.
class TrustedContactsScreen extends ConsumerWidget {
  const TrustedContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final trustedContacts = ref.watch(
      chatControllerProvider.select(
        (s) => s.knownContacts.where((c) => c.isTrusted).toList(),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Invited Friends')),
      body: trustedContacts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: _EmptySettingsCard(
                  icon: Icons.verified_outlined,
                  title: 'No invited friends yet',
                  message:
                      'Long-press a peer in the Nearby screen or open a private conversation to add them to invited friends.',
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: trustedContacts.length,
              itemBuilder: (context, index) {
                final contact = trustedContacts[index];
                final nodeSnippet = contact.nodeId.length > 12
                    ? '${contact.nodeId.substring(0, 12)}...'
                    : contact.nodeId;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: cs.outlineVariant.withAlpha(80),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: cs.primaryContainer,
                        child: Icon(
                          Icons.verified,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        contact.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            nodeSnippet,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            contact.walkieAlwaysOn
                                ? 'Walkie always-on is enabled'
                                : 'Walkie always-on is off',
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch.adaptive(
                            value: contact.walkieAlwaysOn,
                            onChanged: (enabled) async {
                              // Always-on auto-starts sessions, so switching it
                              // on is Plus. Switching it off always works.
                              if (enabled &&
                                  !await ensurePlus(
                                    context,
                                    ref,
                                    gate: (gates) =>
                                        gates.canStartWalkieSession,
                                  )) {
                                return;
                              }
                              if (!context.mounted) return;
                              await ref
                                  .read(chatControllerProvider.notifier)
                                  .setWalkieAlwaysOn(contact.nodeId, enabled);
                            },
                          ),
                          TextButton(
                            onPressed: () async {
                              await ref
                                  .read(chatControllerProvider.notifier)
                                  .untrustContact(contact.nodeId);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Removed from invited friends'),
                                  duration: Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: cs.error,
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _EmptySettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptySettingsCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 30, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
