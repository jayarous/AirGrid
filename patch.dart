import 'dart:io';

void main() {
  final file = File('airgrid/lib/features/home/home_screen.dart');
  var content = file.readAsStringSync();

  content = content.replaceAll(
    'return Scaffold(',
    'return Scaffold(\\n      backgroundColor: cs.surface,'
  );

  content = content.replaceAll(
    'appBar: AppBar(',
    'appBar: AppBar(\\n        elevation: 0,\\n        scrolledUnderElevation: 2,\\n        backgroundColor: cs.surface.withAlpha(240),'
  );

  content = content.replaceAll(
    'height: 34,',
    'height: 32,'
  );

  content = content.replaceAll(
    'ListView(\\n          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),',
    'ListView(\\n          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),'
  );

  content = content.replaceAll(
    'children: [\\n            Text(',
    'children: [\\n            Row(\\n              children: [\\n                CircleAvatar(\\n                  backgroundColor: cs.primaryContainer,\\n                  radius: 26,\\n                  child: Icon(Icons.person_rounded, color: cs.onPrimaryContainer, size: 28),\\n                ),\\n                const SizedBox(width: 16),\\n                Expanded(\\n                  child: Column(\\n                    crossAxisAlignment: CrossAxisAlignment.start,\\n                    children: [\\n                      Text('
  );

  content = content.replaceAll(
    'style: Theme.of(\\n                context,\\n              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),',
    'style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),'
  );

  content = content.replaceAll(
    'style: Theme.of(\\n                context,\\n              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),',
    'style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),\\n                      ),\\n                    ],\\n                  ),\\n                ),\\n              ],\\n            ),'
  );

  content = content.replaceAll(
    'const SizedBox(height: 16),\\n            if (missingPermissions)',
    'const SizedBox(height: 24),\\n            if (missingPermissions)'
  );

  content = content.replaceAll(
    'floatingActionButton: Padding(\\n        padding: const EdgeInsets.only(bottom: 8.0, right: 6.0),\\n        child: FloatingActionButton.extended(\\n          elevation: 6,\\n          shape: RoundedRectangleBorder(\\n            borderRadius: BorderRadius.circular(16),\\n          ),\\n          onPressed: _openPublicChat,\\n          icon: const Icon(Icons.forum),\\n          label: const Text(\\'Public chat\\'),\\n        ),\\n      )',
    'floatingActionButton: FloatingActionButton.extended(\\n        elevation: 4,\\n        hoverElevation: 6,\\n        focusElevation: 6,\\n        highlightElevation: 8,\\n        shape: RoundedRectangleBorder(\\n          borderRadius: BorderRadius.circular(20),\\n        ),\\n        onPressed: _openPublicChat,\\n        icon: const Icon(Icons.forum_rounded),\\n        label: const Text(\\'Public Chat\\', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),\\n      )'
  );

  file.writeAsStringSync(content);
}
