import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Displays all locally saved safety reports with export and clear actions.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  LocalReportStore? _store;

  @override
  void initState() {
    super.initState();
    _store = ref.read(localReportStoreProvider);
  }

  Future<void> _export() async {
    final text = await ref
        .read(chatControllerProvider.notifier)
        .exportReports();
    if (!mounted) return;
    await Share.share(text);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all reports?'),
        content: const Text(
          'This will permanently delete all locally saved safety reports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store!.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reports cleared')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share_outlined),
            tooltip: 'Export',
            onPressed: _export,
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _store!.listAll(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final reports = snapshot.data ?? [];

          if (reports.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: _ReportsEmptyCard(
                  title: 'No reports yet',
                  message:
                      'Reports you submit are stored locally on this device only.',
                ),
              ),
            );
          }

          return Column(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: reports.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final report = reports[index];
                    final ts = report.timestamp;
                    final dateStr =
                        '${ts.year}-${ts.month.toString().padLeft(2, '0')}-'
                        '${ts.day.toString().padLeft(2, '0')} '
                        '${ts.hour.toString().padLeft(2, '0')}:'
                        '${ts.minute.toString().padLeft(2, '0')}';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: cs.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          leading: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: cs.error.withAlpha(22),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.flag_outlined, color: cs.error),
                          ),
                          title: Text(
                            report.reportedDisplayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${report.reason.label} - $dateStr',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  onPressed: _clearAll,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear all reports'),
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReportsEmptyCard extends StatelessWidget {
  final String title;
  final String message;

  const _ReportsEmptyCard({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.flag_outlined, size: 30, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
