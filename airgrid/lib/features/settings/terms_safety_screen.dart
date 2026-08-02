import 'package:airgrid/core/legal_text.dart';
import 'package:flutter/material.dart';

class TermsSafetyScreen extends StatelessWidget {
  const TermsSafetyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Terms & Safety')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    LegalText.shortSafetyNotice,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onErrorContainer,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Version ${LegalText.termsVersion}',
            style: theme.textTheme.labelLarge?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 10),
          for (final section in LegalText.sections) ...[
            Text(
              section.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              section.body,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 18),
          ],
          Text(
            'Privacy Policy: ${LegalText.privacyUrl}\n'
            'Terms URL: ${LegalText.termsUrl}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
