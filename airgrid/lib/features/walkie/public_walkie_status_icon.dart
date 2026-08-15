import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PublicWalkieStatusIcon extends ConsumerWidget {
  const PublicWalkieStatusIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      chatControllerProvider.select(
        (state) =>
            state.walkie.publicStayOnline ||
            state.knownContacts.any(
              (contact) => contact.isTrusted && contact.walkieAlwaysOn,
            ),
      ),
    );

    return Tooltip(
      message: active
          ? 'Turn public walkie offline (Long press to open Walkie)'
          : 'Turn public walkie online (Long press to open Walkie)',
      child: InkResponse(
        radius: 24,
        onTap: () async {
          await ref
              .read(chatControllerProvider.notifier)
              .setPublicWalkieStayOnline(!active);
        },
        onLongPress: () {
          Navigator.of(context).pushNamed(AppRouter.walkie);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Icon(
            Icons.wifi_tethering_rounded,
            color: active ? Colors.green.shade600 : Colors.grey.shade500,
            size: 22,
          ),
        ),
      ),
    );
  }
}
