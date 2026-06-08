import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/foreground_service_bridge.dart';
import 'package:airgrid/core/legal_text.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
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
  StreamSubscription<PrivateMessageNotificationTap>? _notificationTapSub;
  String? _lastPromptedInviteSessionId;
  bool _inviteDialogOpen = false;
  bool _termsDialogOpen = false;
  bool _termsAcceptedThisSession = false;

  @override
  void initState() {
    super.initState();
    final foreground = ref.read(foregroundServiceProvider);
    _notificationTapSub = foreground.privateMessageNotificationTaps.listen(
      _openPrivateMessageNotification,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_consumePendingPrivateMessageNotificationTap());
    });
  }

  @override
  void dispose() {
    unawaited(_notificationTapSub?.cancel());
    super.dispose();
  }

  MeshPeer? _peerByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    final state = ref.read(chatControllerProvider);
    return state.peers.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == nodeId,
      orElse: () => null,
    );
  }

  Future<void> _consumePendingPrivateMessageNotificationTap() async {
    final tap = await ref
        .read(foregroundServiceProvider)
        .consumePendingPrivateMessageTap();
    if (!mounted || tap == null) return;
    await _openPrivateMessageNotification(tap);
  }

  Future<void> _openPrivateMessageNotification(
    PrivateMessageNotificationTap tap,
  ) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || tap.peerNodeId.isEmpty) return;
    final state = ref.read(chatControllerProvider);
    final peer = state.peers.cast<MeshPeer?>().firstWhere(
      (p) => p?.nodeId == tap.peerNodeId,
      orElse: () => null,
    );
    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(
          PrivateConversation(
            peerNodeId: tap.peerNodeId,
            peerName: peer?.displayName ?? tap.peerName,
          ),
        );
    await navigator.pushNamed(AppRouter.chat);
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
        builder: (ctx) => _IncomingWalkieInviteDialog(
          peer: peer,
          onDecline: () => Navigator.of(ctx).pop(false),
          onAccept: () => Navigator.of(ctx).pop(true),
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

  Future<void> _showTermsPromptIfNeeded() async {
    if (_termsDialogOpen || _termsAcceptedThisSession) return;
    if (!widget.identityStore.hasIdentity ||
        widget.identityStore.hasAcceptedTerms(LegalText.termsVersion)) {
      return;
    }

    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) return;

    _termsDialogOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: navigatorContext,
        barrierDismissible: false,
        builder: (ctx) => _TermsAcceptanceDialog(
          onReviewTerms: () => Navigator.of(ctx).pushNamed(AppRouter.legal),
        ),
      );
      if (!mounted || accepted != true) return;
      await widget.identityStore.acceptTerms(LegalText.termsVersion);
      _termsAcceptedThisSession = true;
    } finally {
      _termsDialogOpen = false;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showTermsPromptIfNeeded());
    });

    final initialRoute = widget.identityStore.hasIdentity
        ? AppRouter.home
        : AppRouter.onboarding;

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'AirGrid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6CA8)),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6CA8)),
      ),
      initialRoute: initialRoute,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}

class _IncomingWalkieInviteDialog extends StatelessWidget {
  const _IncomingWalkieInviteDialog({
    required this.peer,
    required this.onDecline,
    required this.onAccept,
  });

  static const Color _radioAmber = Color(0xFFFFA126);
  static const Color _sheetSurface = Color(0xFF0E1620);
  static const Color _cardSurface = Color(0xFF18212B);

  final MeshPeer peer;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _sheetSurface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withAlpha(22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(95),
                blurRadius: 28,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: _radioAmber.withAlpha(28),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _radioAmber.withAlpha(110)),
                      ),
                      child: const Icon(
                        Icons.keyboard_voice_rounded,
                        color: _radioAmber,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Walkie invite',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Private session request',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white60,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _cardSurface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withAlpha(16)),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 23,
                        backgroundColor: Colors.white12,
                        child: const Icon(Icons.person, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'wants to start a walkie session',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white70,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: Colors.white.withAlpha(150),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Audio stays private between you and this peer.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white60,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onDecline,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          'Decline',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onAccept,
                        icon: const Icon(Icons.call_rounded, size: 18),
                        label: const Text('Accept'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _radioAmber,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TermsAcceptanceDialog extends StatefulWidget {
  final VoidCallback onReviewTerms;

  const _TermsAcceptanceDialog({required this.onReviewTerms});

  @override
  State<_TermsAcceptanceDialog> createState() => _TermsAcceptanceDialogState();
}

class _TermsAcceptanceDialogState extends State<_TermsAcceptanceDialog> {
  bool _accepted = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Terms & Safety'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(LegalText.shortSafetyNotice),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: widget.onReviewTerms,
              icon: const Icon(Icons.gavel_outlined),
              label: const Text('Review Terms of Use'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _accepted,
              onChanged: (value) => setState(() {
                _accepted = value ?? false;
              }),
              title: const Text(LegalText.acknowledgement),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _accepted ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Accept and continue'),
        ),
      ],
    );
  }
}
