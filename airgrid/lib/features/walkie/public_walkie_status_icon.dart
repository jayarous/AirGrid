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
            state.publicWalkieStayOnline ||
            state.knownContacts.any(
              (contact) => contact.isTrusted && contact.walkieAlwaysOn,
            ),
      ),
    );

    return Tooltip(
      message: active
          ? 'Walkie always on enabled'
          : 'Walkie always on disabled',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          Icons.wifi_tethering_rounded,
          color: active ? Colors.green.shade600 : Colors.grey.shade500,
          size: 22,
        ),
      ),
    );
  }
}
