import 'package:flutter/material.dart';

class ProfileAvatarOption {
  const ProfileAvatarOption({
    required this.id,
    required this.icon,
    required this.label,
  });

  final String id;
  final IconData icon;
  final String label;
}

class ProfileAvatarCatalog {
  ProfileAvatarCatalog._();

  static const String defaultId = 'person';

  static const List<ProfileAvatarOption> options = [
    ProfileAvatarOption(id: 'person', icon: Icons.person_rounded, label: 'Person'),
    ProfileAvatarOption(id: 'face', icon: Icons.face_rounded, label: 'Face'),
    ProfileAvatarOption(id: 'sentiment', icon: Icons.sentiment_satisfied_alt_rounded, label: 'Smile'),
    ProfileAvatarOption(id: 'rocket', icon: Icons.rocket_launch_rounded, label: 'Rocket'),
    ProfileAvatarOption(id: 'bolt', icon: Icons.bolt_rounded, label: 'Bolt'),
    ProfileAvatarOption(id: 'shield', icon: Icons.shield_rounded, label: 'Shield'),
    ProfileAvatarOption(id: 'pets', icon: Icons.pets_rounded, label: 'Paw'),
    ProfileAvatarOption(id: 'sports', icon: Icons.sports_esports_rounded, label: 'Gamepad'),
  ];

  static IconData iconFor(String? id) {
    for (final option in options) {
      if (option.id == id) {
        return option.icon;
      }
    }
    return Icons.person_rounded;
  }

  static bool containsId(String id) {
    return options.any((option) => option.id == id);
  }
}

class ProfileAvatarBadge extends StatelessWidget {
  const ProfileAvatarBadge({
    super.key,
    required this.icon,
    required this.isOnline,
    this.radius = 20,
    this.backgroundColor,
    this.iconColor,
    this.showStatusDot = true,
  });

  final IconData icon;
  final bool isOnline;
  final double radius;
  final Color? backgroundColor;
  final Color? iconColor;
  final bool showStatusDot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = isOnline ? Colors.green : Colors.grey;

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: radius,
            backgroundColor: backgroundColor ?? cs.primaryContainer,
            child: Icon(
              icon,
              color: iconColor ?? cs.onPrimaryContainer,
              size: radius + 2,
            ),
          ),
          if (showStatusDot)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: radius * 0.52,
                height: radius * 0.52,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}