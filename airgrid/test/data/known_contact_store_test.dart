import 'dart:convert';

import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

KnownContact _contact(
  String nodeId, {
  bool isBlocked = false,
  bool isTrusted = false,
  bool isChatClosed = false,
}) {
  return KnownContact(
    nodeId: nodeId,
    displayName: nodeId,
    publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    lastSeenAt: DateTime(2024, 1, 1),
    isBlocked: isBlocked,
    isTrusted: isTrusted,
    isChatClosed: isChatClosed,
  );
}

/// Runs the full blocking test suite against any [KnownContactStore].
void _blockingTests(
  String label,
  Future<KnownContactStore> Function() makeStore,
) {
  group(label, () {
    late KnownContactStore store;

    setUp(() async {
      store = await makeStore();
    });

    tearDown(() => store.dispose());

    test('block marks contact as blocked', () async {
      await store.upsert(_contact('node-1'));
      await store.block('node-1');
      expect(store.isBlocked('node-1'), isTrue);
    });

    test('unblock removes block', () async {
      await store.upsert(_contact('node-1', isBlocked: true));
      await store.unblock('node-1');
      expect(store.isBlocked('node-1'), isFalse);
    });

    test('isBlocked returns false for unknown nodeId', () {
      expect(store.isBlocked('no-such-node'), isFalse);
    });

    test('block on unknown nodeId is silently ignored', () async {
      // Should not throw.
      await store.block('no-such-node');
      expect(store.isBlocked('no-such-node'), isFalse);
    });

    test('block on already-blocked is idempotent', () async {
      await store.upsert(_contact('node-1'));
      await store.block('node-1');
      await store.block('node-1'); // second call
      expect(store.isBlocked('node-1'), isTrue);
    });

    test('unblock on already-unblocked is idempotent', () async {
      await store.upsert(_contact('node-1'));
      await store.unblock('node-1'); // not blocked yet
      expect(store.isBlocked('node-1'), isFalse);
    });

    test('upsert preserves existing blocked status', () async {
      await store.upsert(_contact('node-1'));
      await store.block('node-1');

      await store.upsert(
        KnownContact(
          nodeId: 'node-1',
          displayName: 'Updated name',
          publicKeyBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
          lastSeenAt: DateTime(2024, 1, 2),
        ),
      );

      expect(store.isBlocked('node-1'), isTrue);
    });

    test('blockedContacts returns only blocked entries', () async {
      await store.upsert(_contact('node-1'));
      await store.upsert(_contact('node-2'));
      await store.upsert(_contact('node-3'));
      await store.block('node-1');
      await store.block('node-3');

      final ids = store.blockedContacts.map((c) => c.nodeId).toSet();
      expect(ids, equals({'node-1', 'node-3'}));
    });

    test('blockedContacts is empty when none blocked', () async {
      await store.upsert(_contact('node-1'));
      expect(store.blockedContacts, isEmpty);
    });

    test('contactsStream emits after block', () async {
      await store.upsert(_contact('node-1'));

      final emitted = <List<KnownContact>>[];
      final sub = store.contactsStream.listen(emitted.add);

      await store.block('node-1');
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isNotEmpty);
      final lastContacts = emitted.last;
      expect(lastContacts.first.isBlocked, isTrue);

      await sub.cancel();
    });

    test('contactsStream emits after unblock', () async {
      await store.upsert(_contact('node-1'));
      await store.block('node-1');

      final emitted = <List<KnownContact>>[];
      final sub = store.contactsStream.listen(emitted.add);

      await store.unblock('node-1');
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isNotEmpty);
      expect(emitted.last.first.isBlocked, isFalse);

      await sub.cancel();
    });
  });
}

void _trustTests(
  String label,
  Future<KnownContactStore> Function() makeStore,
) {
  group(label, () {
    late KnownContactStore store;

    setUp(() async {
      store = await makeStore();
    });

    tearDown(() => store.dispose());

    test('trust marks contact as trusted', () async {
      await store.upsert(_contact('node-1'));
      await store.trust('node-1');
      expect(store.isTrusted('node-1'), isTrue);
    });

    test('untrust removes trust', () async {
      await store.upsert(_contact('node-1', isTrusted: true));
      await store.untrust('node-1');
      expect(store.isTrusted('node-1'), isFalse);
    });

    test('isTrusted returns false for unknown nodeId', () {
      expect(store.isTrusted('no-such-node'), isFalse);
    });

    test('trustedContacts returns only trusted entries', () async {
      await store.upsert(_contact('node-1'));
      await store.upsert(_contact('node-2'));
      await store.upsert(_contact('node-3'));
      await store.trust('node-1');
      await store.trust('node-3');

      final ids = store.trustedContacts.map((c) => c.nodeId).toSet();
      expect(ids, equals({'node-1', 'node-3'}));
    });

    test('upsert preserves existing trusted status', () async {
      await store.upsert(_contact('node-1'));
      await store.trust('node-1');

      await store.upsert(
        KnownContact(
          nodeId: 'node-1',
          displayName: 'Updated name',
          publicKeyBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
          lastSeenAt: DateTime(2024, 1, 2),
        ),
      );

      expect(store.isTrusted('node-1'), isTrue);
    });
  });
}

void _chatCloseTests(
  String label,
  Future<KnownContactStore> Function() makeStore,
) {
  group(label, () {
    late KnownContactStore store;

    setUp(() async {
      store = await makeStore();
    });

    tearDown(() => store.dispose());

    test('closeChat marks contact chat as closed', () async {
      await store.upsert(_contact('node-1'));
      await store.closeChat('node-1');
      expect(store.isChatClosed('node-1'), isTrue);
    });

    test('reopenChat clears closed state', () async {
      await store.upsert(_contact('node-1', isChatClosed: true));
      await store.reopenChat('node-1');
      expect(store.isChatClosed('node-1'), isFalse);
    });

    test('closedContacts returns only closed chats', () async {
      await store.upsert(_contact('node-1'));
      await store.upsert(_contact('node-2', isChatClosed: true));
      await store.upsert(_contact('node-3', isChatClosed: true));

      final ids = store.closedContacts.map((c) => c.nodeId).toSet();
      expect(ids, equals({'node-2', 'node-3'}));
    });

    test('upsert preserves existing closed chat state', () async {
      await store.upsert(_contact('node-1'));
      await store.closeChat('node-1');

      await store.upsert(
        KnownContact(
          nodeId: 'node-1',
          displayName: 'Updated name',
          publicKeyBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
          lastSeenAt: DateTime(2024, 1, 2),
        ),
      );

      expect(store.isChatClosed('node-1'), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// SharedPrefs-specific tests
// ---------------------------------------------------------------------------

void _sharedPrefsTests() {
  group('SharedPrefsKnownContactStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('persists block across instantiations', () async {
      final store1 = await SharedPrefsKnownContactStore.create();
      await store1.upsert(_contact('node-1'));
      await store1.block('node-1');
      await store1.dispose();

      final store2 = await SharedPrefsKnownContactStore.create();
      expect(store2.isBlocked('node-1'), isTrue);
      await store2.dispose();
    });

    test('backward compat: JSON without isBlocked field loads as false', () async {
      // Seed SharedPrefs with old-format JSON (no isBlocked field).
      final legacy = jsonEncode([
        {
          'nodeId': 'node-old',
          'displayName': 'OldNode',
          'publicKeyBase64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'lastSeenAt': DateTime(2024).millisecondsSinceEpoch,
        }
      ]);
      SharedPreferences.setMockInitialValues({
        'airgrid_known_contacts': legacy,
      });

      final store = await SharedPrefsKnownContactStore.create();
      expect(store.isBlocked('node-old'), isFalse);
      await store.dispose();
    });

    test('block status persists after unblock and re-block', () async {
      final store1 = await SharedPrefsKnownContactStore.create();
      await store1.upsert(_contact('node-1'));
      await store1.block('node-1');
      await store1.unblock('node-1');
      await store1.block('node-1');
      await store1.dispose();

      final store2 = await SharedPrefsKnownContactStore.create();
      expect(store2.isBlocked('node-1'), isTrue);
      await store2.dispose();
    });

    test('closed chat state persists across instantiations', () async {
      final store1 = await SharedPrefsKnownContactStore.create();
      await store1.upsert(_contact('node-1'));
      await store1.closeChat('node-1');
      await store1.dispose();

      final store2 = await SharedPrefsKnownContactStore.create();
      expect(store2.isChatClosed('node-1'), isTrue);
      await store2.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  _blockingTests(
    'InMemoryKnownContactStore — blocking',
    () async => InMemoryKnownContactStore(),
  );

  group('SharedPrefsKnownContactStore — blocking', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    _blockingTests(
      'SharedPrefsKnownContactStore (blocking contract)',
      () async {
        SharedPreferences.setMockInitialValues({});
        return SharedPrefsKnownContactStore.create();
      },
    );
  });

  _trustTests(
    'InMemoryKnownContactStore — trust',
    () async => InMemoryKnownContactStore(),
  );

  group('SharedPrefsKnownContactStore — trust', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    _trustTests(
      'SharedPrefsKnownContactStore (trust contract)',
      () async {
        SharedPreferences.setMockInitialValues({});
        return SharedPrefsKnownContactStore.create();
      },
    );
  });

  _sharedPrefsTests();

  _chatCloseTests(
    'InMemoryKnownContactStore — close chat',
    () async => InMemoryKnownContactStore(),
  );

  group('SharedPrefsKnownContactStore — close chat', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    _chatCloseTests(
      'SharedPrefsKnownContactStore (close chat contract)',
      () async {
        SharedPreferences.setMockInitialValues({});
        return SharedPrefsKnownContactStore.create();
      },
    );
  });
}
