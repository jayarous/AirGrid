import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Global help mode state. When true, help affordances (badges) are shown
/// next to actionable controls throughout the app.
final helpModeProvider = StateProvider<bool>((ref) => false);
