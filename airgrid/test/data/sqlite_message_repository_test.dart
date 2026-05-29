import 'dart:io';

import 'package:airgrid/data/storage/sqlite_message_repository.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

AirGridMessage _msg({
  String id = 'msg-1',
  String senderNodeId = 'node-a',
  String senderName = 'Alice',
  String content = 'Hello',
  bool isLocal = false,
  DateTime? timestamp,
}) {
  return AirGridMessage(
    id: id,
    senderNodeId: senderNodeId,
    senderName: senderName,
    content: content,
    isLocal: isLocal,
    timestamp: timestamp ?? DateTime(2026, 1, 1, 12, 0),
  );
}

class _TempRepo {
  final Directory dir;
  final String path;
  final SqliteMessageRepository repo;

  const _TempRepo({required this.dir, required this.path, required this.repo});

  Future<void> close() async {
    await repo.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<SqliteMessageRepository> openInMemory() =>
      SqliteMessageRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );

  Future<_TempRepo> openTempRepo() async {
    final dir = Directory.systemTemp.createTempSync('airgrid_messages_test_');
    final path = p.join(dir.path, 'messages.db');
    final repo = await SqliteMessageRepository.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    return _TempRepo(dir: dir, path: path, repo: repo);
  }

  Future<void> setReceivedAt(
    String dbPath,
    String id,
    DateTime receivedAt,
  ) async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.update(
      'messages',
      {'received_at': receivedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    await db.close();
  }

  group('SqliteMessageRepository', () {
    test('empty database returns empty list', () async {
      final repo = await openInMemory();
      final result = await repo.loadRecent();
      expect(result, isEmpty);
      await repo.close();
    });

    test('save and loadRecent round-trips all fields', () async {
      final repo = await openInMemory();
      final msg = _msg(
        id: 'round-trip-1',
        senderNodeId: 'node-x',
        senderName: 'Bob',
        content: 'Round trip',
        isLocal: true,
        timestamp: DateTime(2026, 5, 1, 9, 30),
      );

      await repo.save(msg);
      final loaded = await repo.loadRecent();

      expect(loaded, hasLength(1));
      final m = loaded.first;
      expect(m.id, msg.id);
      expect(m.senderNodeId, msg.senderNodeId);
      expect(m.senderName, msg.senderName);
      expect(m.content, msg.content);
      expect(m.isLocal, msg.isLocal);
      expect(m.timestamp, msg.timestamp);

      await repo.close();
    });

    test('duplicate save is ignored', () async {
      final repo = await openInMemory();
      final msg = _msg(id: 'dup-1');

      await repo.save(msg);
      await repo.save(msg); // second save — should not throw or duplicate

      final result = await repo.loadRecent();
      expect(result, hasLength(1));
      await repo.close();
    });

    test('loadRecent returns newest first (by received_at)', () async {
      final repo = await openInMemory();

      // Insert in order A, B, C — each with a small delay isn't reliable in
      // tests, so we trust that sequential inserts get monotonically increasing
      // received_at from DateTime.now(). To make order deterministic we insert
      // three messages and verify the most recently inserted comes first.
      await repo.save(_msg(id: 'order-1', content: 'First'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.save(_msg(id: 'order-2', content: 'Second'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.save(_msg(id: 'order-3', content: 'Third'));

      final result = await repo.loadRecent();
      expect(result[0].id, 'order-3');
      expect(result[1].id, 'order-2');
      expect(result[2].id, 'order-1');

      await repo.close();
    });

    test('loadRecent respects limit', () async {
      final repo = await openInMemory();

      for (var i = 1; i <= 10; i++) {
        await repo.save(_msg(id: 'limit-$i'));
      }

      final result = await repo.loadRecent(limit: 3);
      expect(result, hasLength(3));
      await repo.close();
    });

    test('isLocal flag persists correctly for both values', () async {
      final repo = await openInMemory();
      await repo.save(_msg(id: 'local-msg', isLocal: true));
      await repo.save(_msg(id: 'remote-msg', isLocal: false));

      final result = await repo.loadRecent();
      final local = result.firstWhere((m) => m.id == 'local-msg');
      final remote = result.firstWhere((m) => m.id == 'remote-msg');

      expect(local.isLocal, isTrue);
      expect(remote.isLocal, isFalse);
      await repo.close();
    });

    test('private message round-trips conversation fields', () async {
      final repo = await openInMemory();
      final privateMsg = AirGridMessage(
        id: 'priv-rt-db-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        content: 'Private content',
        isLocal: false,
        timestamp: DateTime(2026, 6, 1, 10, 0),
        conversationType: 'private',
        peerNodeId: 'node-bob',
        peerName: 'Bob',
        isRead: false,
      );

      await repo.save(privateMsg);
      final loaded = await repo.loadRecent();

      expect(loaded, hasLength(1));
      final m = loaded.first;
      expect(m.conversationType, 'private');
      expect(m.peerNodeId, 'node-bob');
      expect(m.peerName, 'Bob');
      expect(m.isRead, isFalse);
      await repo.close();
    });

    test(
      'markPrivateThreadRead marks incoming messages from peer read',
      () async {
        final repo = await openInMemory();
        await repo.save(
          _msg(
            id: 'incoming-private',
            senderNodeId: 'node-alice',
          ).copyWith(isRead: false),
        );
        await repo.save(
          AirGridMessage(
            id: 'incoming-private-thread',
            senderNodeId: 'node-alice',
            senderName: 'Alice',
            content: 'Private content',
            isLocal: false,
            timestamp: DateTime(2026, 6, 1, 10, 0),
            conversationType: 'private',
            peerNodeId: 'node-alice',
            peerName: 'Alice',
            isRead: false,
          ),
        );

        await repo.markPrivateThreadRead('node-alice');
        final loaded = await repo.loadRecent();

        expect(
          loaded.firstWhere((m) => m.id == 'incoming-private-thread').isRead,
          isTrue,
        );
        await repo.close();
      },
    );

    test('public message has conversationType public by default', () async {
      final repo = await openInMemory();
      await repo.save(_msg(id: 'pub-default'));
      final loaded = await repo.loadRecent();
      expect(loaded.first.conversationType, 'public');
      await repo.close();
    });

    test('clearAll removes all persisted messages', () async {
      final repo = await openInMemory();
      await repo.save(_msg(id: 'clear-1'));
      await repo.save(_msg(id: 'clear-2'));

      await repo.clearAll();

      expect(await repo.loadRecent(), isEmpty);
      await repo.close();
    });

    test('prune deletes messages older than maxAge', () async {
      final temp = await openTempRepo();
      addTearDown(temp.close);
      final now = DateTime.now();

      await temp.repo.save(_msg(id: 'old'));
      await temp.repo.save(_msg(id: 'fresh'));
      await setReceivedAt(
        temp.path,
        'old',
        now.subtract(const Duration(days: 31)),
      );
      await setReceivedAt(
        temp.path,
        'fresh',
        now.subtract(const Duration(days: 1)),
      );

      final deleted = await temp.repo.prune(
        maxMessages: 1000,
        maxAge: const Duration(days: 30),
      );
      final loaded = await temp.repo.loadRecent();

      expect(deleted, 1);
      expect(loaded.map((m) => m.id), ['fresh']);
    });

    test('prune keeps only newest maxMessages', () async {
      final temp = await openTempRepo();
      addTearDown(temp.close);
      final base = DateTime.now();

      for (var i = 1; i <= 5; i++) {
        final id = 'count-$i';
        await temp.repo.save(_msg(id: id));
        await setReceivedAt(temp.path, id, base.add(Duration(minutes: i)));
      }

      final deleted = await temp.repo.prune(
        maxMessages: 3,
        maxAge: const Duration(days: 30),
      );
      final loaded = await temp.repo.loadRecent();

      expect(deleted, 2);
      expect(loaded.map((m) => m.id), ['count-5', 'count-4', 'count-3']);
    });

    test(
      'prune returns deleted row count across age and count limits',
      () async {
        final temp = await openTempRepo();
        addTearDown(temp.close);
        final now = DateTime.now();

        await temp.repo.save(_msg(id: 'old-1'));
        await temp.repo.save(_msg(id: 'old-2'));
        await temp.repo.save(_msg(id: 'new-1'));
        await temp.repo.save(_msg(id: 'new-2'));
        await temp.repo.save(_msg(id: 'new-3'));
        await setReceivedAt(
          temp.path,
          'old-1',
          now.subtract(const Duration(days: 40)),
        );
        await setReceivedAt(
          temp.path,
          'old-2',
          now.subtract(const Duration(days: 35)),
        );
        await setReceivedAt(
          temp.path,
          'new-1',
          now.subtract(const Duration(days: 3)),
        );
        await setReceivedAt(
          temp.path,
          'new-2',
          now.subtract(const Duration(days: 2)),
        );
        await setReceivedAt(
          temp.path,
          'new-3',
          now.subtract(const Duration(days: 1)),
        );

        final deleted = await temp.repo.prune(
          maxMessages: 2,
          maxAge: const Duration(days: 30),
        );
        final loaded = await temp.repo.loadRecent();

        expect(deleted, 3);
        expect(loaded.map((m) => m.id), ['new-3', 'new-2']);
      },
    );

    group('Schema Migration', () {
      test('fresh database has covering index', () async {
        final temp = await openTempRepo();
        addTearDown(temp.close);

        // Query sqlite_master to verify index exists
        final db = await databaseFactoryFfi.openDatabase(
          temp.path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final indices = await db.rawQuery(
          "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='messages' AND name NOT LIKE 'sqlite_%'",
        );
        await db.close();

        // Should have the covering index, not the old single-column index
        expect(indices.length, 1);
        expect(indices[0]['name'], 'idx_received_at_id');
        expect(indices[0]['sql'], contains('received_at DESC, id'));
      });

      test('migration from v3 to v4 replaces index', () async {
        final dir = Directory.systemTemp.createTempSync('airgrid_migration_');
        final dbPath = p.join(dir.path, 'messages_v3.db');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        // Create v3 database with old index
        var db = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, version) async {
              await db.execute('''
                CREATE TABLE messages (
                  id TEXT PRIMARY KEY,
                  packet_id TEXT NOT NULL,
                  sender_node_id TEXT NOT NULL,
                  sender_name TEXT NOT NULL,
                  content TEXT NOT NULL,
                  timestamp INTEGER NOT NULL,
                  received_at INTEGER NOT NULL,
                  is_local INTEGER NOT NULL,
                  encryption_state TEXT NOT NULL DEFAULT 'plaintext',
                  conversation_type TEXT NOT NULL DEFAULT 'public',
                  peer_node_id TEXT,
                  peer_name TEXT,
                  delivery_status TEXT NOT NULL DEFAULT 'sent'
                )
              ''');
              await db.execute(
                'CREATE INDEX idx_received_at ON messages (received_at DESC)',
              );
            },
          ),
        );

        // Insert test data
        await db.insert('messages', {
          'id': 'migrate-1',
          'packet_id': 'migrate-1',
          'sender_node_id': 'node-test',
          'sender_name': 'Test',
          'content': 'Migration test',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'received_at': DateTime.now().millisecondsSinceEpoch,
          'is_local': 1,
          'encryption_state': 'plaintext',
          'conversation_type': 'public',
          'delivery_status': 'sent',
        });
        await db.close();

        // Open with v4 to trigger migration
        final repo = await SqliteMessageRepository.open(
          path: dbPath,
          factory: databaseFactoryFfi,
        );

        // Verify data survived migration
        final loaded = await repo.loadRecent();
        expect(loaded, hasLength(1));
        expect(loaded.first.id, 'migrate-1');
        await repo.close();

        // Verify new index exists and old one is gone
        db = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final indices = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messages' AND name NOT LIKE 'sqlite_%'",
        );
        await db.close();

        expect(indices.map((r) => r['name']), ['idx_received_at_id']);
      });

      test('loadRecent ordering works after migration', () async {
        final dir = Directory.systemTemp.createTempSync('airgrid_ordering_');
        final dbPath = p.join(dir.path, 'messages_ordering.db');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        // Create v3 database
        final db = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, _) async {
              await db.execute('''
              CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                packet_id TEXT NOT NULL,
                sender_node_id TEXT NOT NULL,
                sender_name TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                received_at INTEGER NOT NULL,
                is_local INTEGER NOT NULL,
                encryption_state TEXT NOT NULL DEFAULT 'plaintext',
                conversation_type TEXT NOT NULL DEFAULT 'public',
                peer_node_id TEXT,
                peer_name TEXT,
                delivery_status TEXT NOT NULL DEFAULT 'sent'
              )
            ''');
              await db.execute(
                'CREATE INDEX idx_received_at ON messages (received_at DESC)',
              );
            },
          ),
        );

        // Insert messages with explicit received_at ordering
        final base = DateTime(2026, 5, 27, 10, 0, 0);
        for (var i = 1; i <= 5; i++) {
          await db.insert('messages', {
            'id': 'order-$i',
            'packet_id': 'order-$i',
            'sender_node_id': 'node-test',
            'sender_name': 'Test',
            'content': 'Message $i',
            'timestamp': base.add(Duration(minutes: i)).millisecondsSinceEpoch,
            'received_at': base
                .add(Duration(minutes: i))
                .millisecondsSinceEpoch,
            'is_local': 1,
            'encryption_state': 'plaintext',
            'conversation_type': 'public',
            'delivery_status': 'sent',
          });
        }
        await db.close();

        // Migrate to v4
        final repo = await SqliteMessageRepository.open(
          path: dbPath,
          factory: databaseFactoryFfi,
        );

        // Verify ordering: newest first
        final loaded = await repo.loadRecent();
        expect(loaded.map((m) => m.id), [
          'order-5',
          'order-4',
          'order-3',
          'order-2',
          'order-1',
        ]);

        await repo.close();
      });

      test('prune works correctly with new index', () async {
        final temp = await openTempRepo();
        addTearDown(temp.close);
        final base = DateTime.now();

        // Insert messages with specific received_at times
        for (var i = 1; i <= 10; i++) {
          final id = 'prune-idx-$i';
          await temp.repo.save(_msg(id: id));
          await setReceivedAt(temp.path, id, base.add(Duration(minutes: i)));
        }

        // Prune to keep only 5 newest
        final deleted = await temp.repo.prune(
          maxMessages: 5,
          maxAge: const Duration(days: 365),
        );

        expect(deleted, 5);

        final loaded = await temp.repo.loadRecent();
        expect(loaded.map((m) => m.id), [
          'prune-idx-10',
          'prune-idx-9',
          'prune-idx-8',
          'prune-idx-7',
          'prune-idx-6',
        ]);
      });
    });
  });
}
