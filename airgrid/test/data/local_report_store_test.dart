import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocalReport _report({String id = 'node-a', String name = 'Alice'}) {
  return LocalReport(
    timestamp: DateTime(2024, 1, 1, 12),
    reporterNodeId: 'local-node',
    reportedNodeId: id,
    reportedDisplayName: name,
    reason: ReportReason.spam,
  );
}

void _contractTests(
  String label,
  Future<LocalReportStore> Function() makeStore,
) {
  group(label, () {
    late LocalReportStore store;

    setUp(() async {
      store = await makeStore();
    });

    test('add + listAll returns inserted reports', () async {
      await store.add(_report(id: 'node-a', name: 'Alice'));
      await store.add(_report(id: 'node-b', name: 'Bob'));

      final all = await store.listAll();
      expect(all, hasLength(2));
      expect(all[0].reportedNodeId, 'node-a');
      expect(all[1].reportedNodeId, 'node-b');
    });

    test('clear removes all reports', () async {
      await store.add(_report());
      await store.clear();
      final all = await store.listAll();
      expect(all, isEmpty);
    });

    test('exportText includes report details', () async {
      await store.add(_report(id: 'node-z', name: 'Zed'));
      final text = await store.exportText();
      expect(text, contains('Zed'));
      expect(text, contains('Spam'));
    });
  });
}

void main() {
  _contractTests('InMemoryLocalReportStore', () async => InMemoryLocalReportStore());

  group('SharedPrefsLocalReportStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    _contractTests(
      'SharedPrefsLocalReportStore contract',
      () async {
        SharedPreferences.setMockInitialValues({});
        return SharedPrefsLocalReportStore.create();
      },
    );

    test('persists reports across re-instantiation', () async {
      final s1 = await SharedPrefsLocalReportStore.create();
      await s1.add(_report(id: 'node-persist', name: 'Persisted'));

      final s2 = await SharedPrefsLocalReportStore.create();
      final all = await s2.listAll();
      expect(all.map((r) => r.reportedNodeId), contains('node-persist'));
    });
  });
}
