const fs = require('fs'); let code = fs.readFileSync('airgrid/lib/features/home/home_screen.dart', 'utf8');
code = code.replace(/class _QuickActions extends StatelessWidget \\{[\\s\\S]*?return Row\\([\\s\\S]*?\\];\\n  \\}\\n\\}/, \class _QuickActions extends StatelessWidget {
  final VoidCallback onOpenPublicChat;
  final VoidCallback onOpenNearby;
  final VoidCallback onOpenWalkie;

  const _QuickActions({
    required this.onOpenPublicChat,
    required this.onOpenNearby,
    required this.onOpenWalkie,
  });

  Widget _buildActionCard(BuildContext context, String title, IconData icon, VoidCallback onTap, {bool isPrimary = false}) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: isPrimary ? cs.primary : cs.surfaceContainerHighest.withAlpha(150),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: isPrimary ? cs.onPrimary : cs.primary,
                  size: 28,
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    color: isPrimary ? cs.onPrimary : cs.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _buildActionCard(context, 'Public', Icons.forum_rounded, onOpenPublicChat, isPrimary: true),
        const SizedBox(width: 12),
        _buildActionCard(context, 'Nearby', Icons.radar_rounded, onOpenNearby),
        const SizedBox(width: 12),
        _buildActionCard(context, 'Walkie', Icons.keyboard_voice_rounded, onOpenWalkie),
      ],
    );
  }
}\);
fs.writeFileSync('airgrid/lib/features/home/home_screen.dart', code);
