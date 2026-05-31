import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AirGridApp extends ConsumerStatefulWidget {
  final LocalIdentityStore identityStore;

  const AirGridApp({super.key, required this.identityStore});

  @override
  ConsumerState<AirGridApp> createState() => _AirGridAppState();
}

class _AirGridAppState extends ConsumerState<AirGridApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  String? _lastPromptedInviteSessionId;
  bool _inviteDialogOpen = false;

  MeshPeer? _peerByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    final state = ref.read(chatControllerProvider);
    return state.peers.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == nodeId,
      orElse: () => null,
    );
  }

  Future<void> _showIncomingInvitePrompt() async {
    final controller = ref.read(chatControllerProvider.notifier);
    final state = ref.read(chatControllerProvider);
    final navigator = _navigatorKey.currentState;
    final navigatorContext = _navigatorKey.currentContext;
    final peer = _peerByNodeId(state.walkieInvitePeerNodeId);
    final sessionId = state.walkieInviteSessionId;
    if (peer == null ||
        sessionId == null ||
        !state.walkieInviteIsIncoming ||
        navigator == null ||
        navigatorContext == null) {
      return;
    }

    _inviteDialogOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: navigatorContext,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Walkie invite'),
          content: Text('${peer.displayName} wants to start a walkie session.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Accept'),
            ),
          ],
        ),
      );

      if (!mounted) return;
      if (accepted == true) {
        await controller.acceptWalkieInvite();
        if (!mounted) return;
        unawaited(navigator.pushNamed(AppRouter.walkie));
      } else {
        await controller.declineWalkieInvite();
      }
    } finally {
      _inviteDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      chatControllerProvider.select((state) => state.walkieInviteSessionId),
      (previous, next) {
        if (!mounted || _inviteDialogOpen) return;
        final state = ref.read(chatControllerProvider);
        if (!state.walkieInviteIsIncoming || next == null) return;
        if (_lastPromptedInviteSessionId == next) return;
        _lastPromptedInviteSessionId = next;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_showIncomingInvitePrompt());
        });
      },
    );

    final initialRoute = widget.identityStore.hasIdentity
        ? AppRouter.home
        : AppRouter.onboarding;

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'AirGrid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B6CA8),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B6CA8),
        ),
      ),
      initialRoute: initialRoute,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
