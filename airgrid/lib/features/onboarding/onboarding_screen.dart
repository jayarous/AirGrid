import 'dart:async';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/validation.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _nameController = TextEditingController();
  int _step = 0; // 0=intro, 1=name

  @override
  void initState() {
    super.initState();
    final savedName = ref.read(localIdentityStoreProvider).displayName;
    if (savedName != null && savedName.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRouter.home);
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ── Steps ────────────────────────────────────────────────────────────────

  Widget _buildIntroStep() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/airgrid_stacked.png',
          width: 260,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 24),
        const Text(
          'Peer-to-peer mesh chat that works\n'
          'without internet, Wi-Fi routers,\n'
          'or mobile data.\n\n'
          'Messages travel device-to-device\n'
          'through nearby Android phones.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, height: 1.6),
        ),
        const SizedBox(height: 40),
        FilledButton(
          onPressed: () {
            final savedName = ref.read(localIdentityStoreProvider).displayName;
            if (savedName != null && savedName.trim().isNotEmpty) {
              Navigator.of(context).pushReplacementNamed(AppRouter.home);
              return;
            }
            setState(() {
              _step = 1;
            });
          },
          child: const Text('Get started'),
        ),
      ],
    );
  }

  Widget _buildNameStep() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'What should others see\nas your name?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 32),
        TextField(
          controller: _nameController,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Display name',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _saveNameAndContinue(),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saveNameAndContinue,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  // ── Logic ────────────────────────────────────────────────────────────────

  Future<void> _saveNameAndContinue() async {
    final name = _nameController.text;
    final validation = DisplayNameValidator.validateLocal(name);

    if (!validation.isValid) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validation.error!)));
      return;
    }

    // Save the sanitized value
    await ref
        .read(localIdentityStoreProvider)
        .saveDisplayName(validation.sanitizedValue!);
    if (!mounted) return;
    unawaited(Navigator.of(context).pushReplacementNamed(AppRouter.home));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (_step) {
      case 1:
        body = _buildNameStep();
      default:
        body = _buildIntroStep();
    }

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(child: body),
              ),
            );
          },
        ),
      ),
    );
  }
}
