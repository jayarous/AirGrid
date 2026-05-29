import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:flutter/material.dart';

class AirGridApp extends StatelessWidget {
  final LocalIdentityStore identityStore;

  const AirGridApp({super.key, required this.identityStore});

  @override
  Widget build(BuildContext context) {
    final initialRoute = identityStore.hasIdentity
        ? AppRouter.home
        : AppRouter.onboarding;

    return MaterialApp(
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
