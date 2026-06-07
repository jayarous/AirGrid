import 'package:airgrid/features/chat/chat_screen.dart';
import 'package:airgrid/features/home/home_screen.dart';
import 'package:airgrid/features/nearby/nearby_screen.dart';
import 'package:airgrid/features/onboarding/onboarding_screen.dart';
import 'package:airgrid/features/settings/profile_edit_screen.dart';
import 'package:airgrid/features/settings/reports_screen.dart';
import 'package:airgrid/features/settings/settings_screen.dart';
import 'package:airgrid/features/settings/terms_safety_screen.dart';
import 'package:airgrid/features/settings/trusted_contacts_screen.dart';
import 'package:airgrid/features/walkie/walkie_screen.dart';
import 'package:flutter/material.dart';

/// Centralised route definitions.
class AppRouter {
  AppRouter._();

  static const String home = '/';
  static const String onboarding = '/onboarding';
  static const String chat = '/chat';
  static const String nearby = '/nearby';
  static const String walkie = '/walkie';
  static const String settings = '/settings';
  static const String profileEdit = '/settings/profile';
  static const String trustedContacts = '/settings/trusted';
  static const String reports = '/settings/reports';
  static const String legal = '/settings/legal';

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case home:
        return MaterialPageRoute(
          builder: (_) => const HomeScreen(),
          settings: settings,
        );
      case onboarding:
        return MaterialPageRoute(
          builder: (_) => const OnboardingScreen(),
          settings: settings,
        );
      case chat:
        return MaterialPageRoute(
          builder: (_) => const ChatScreen(),
          settings: settings,
        );
      case nearby:
        return MaterialPageRoute(
          builder: (_) => const NearbyScreen(),
          settings: settings,
        );
      case walkie:
        return MaterialPageRoute(
          builder: (_) => const WalkieScreen(),
          settings: settings,
        );
      case AppRouter.settings:
        return MaterialPageRoute(
          builder: (_) => const SettingsScreen(),
          settings: settings,
        );
      case profileEdit:
        return MaterialPageRoute(
          builder: (_) => const ProfileEditScreen(),
          settings: settings,
        );
      case trustedContacts:
        return MaterialPageRoute(
          builder: (_) => const TrustedContactsScreen(),
          settings: settings,
        );
      case reports:
        return MaterialPageRoute(
          builder: (_) => const ReportsScreen(),
          settings: settings,
        );
      case legal:
        return MaterialPageRoute(
          builder: (_) => const TermsSafetyScreen(),
          settings: settings,
        );
      default:
        return MaterialPageRoute(builder: (_) => const HomeScreen());
    }
  }
}
