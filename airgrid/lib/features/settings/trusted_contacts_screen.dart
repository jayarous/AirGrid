import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Displays all contacts the user has trusted, with a button to remove trust.
class TrustedContactsScreen extends ConsumerWidget {
  const TrustedContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      size: 56,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No invited friends yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Long-press a peer in the Nearby screen or open a private '
                      'conversation to add them to invited friends.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: trustedContacts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final contact = trustedContacts[index];
                final nodeSnippet = contact.nodeId.length > 12
                    ? '${contact.nodeId.substring(0, 12)}…'
                    : contact.nodeId;
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.verified)),
                  title: Text(contact.displayName),
                  subtitle: Text(
                    nodeSnippet,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  isThreeLine: true,
                  trailing: SizedBox(
                    width: 164,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Switch.adaptive(
                          value: contact.walkieAlwaysOn,
                          onChanged: (contact.isTrusted)
                              ? (enabled) async {
                                  await ref
                                      .read(chatControllerProvider.notifier)
                                      .setWalkieAlwaysOn(
                                        contact.nodeId,
                                        enabled,
                                      );
                                }
                              : null,
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
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
