import 'package:airgrid/core/logger.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const _kDbName = 'airgrid_messages.db';
const _kVersion = 7;
const _kTable = 'messages';
const _kVacuumDeletedRowsThreshold = 500;

/// SQLite-backed [MessageRepository].
///
/// Schema is versioned; add future column/index changes to [_onUpgrade].
class SqliteMessageRepository implements MessageRepository {
  final Database _db;

  SqliteMessageRepository._(this._db);

  /// Opens (or creates) the database. Call once at app startup.
  static Future<SqliteMessageRepository> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final dbPath = path ?? p.join(await getDatabasesPath(), _kDbName);
    final db = await (factory ?? databaseFactory).openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _kVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return SqliteMessageRepository._(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_kTable (
        id               TEXT PRIMARY KEY,
        packet_id        TEXT NOT NULL,
        sender_node_id   TEXT NOT NULL,
        sender_name      TEXT NOT NULL,
        content          TEXT NOT NULL,
        timestamp        INTEGER NOT NULL,
        received_at      INTEGER NOT NULL,
        is_local         INTEGER NOT NULL,
        encryption_state TEXT NOT NULL DEFAULT 'plaintext',
        conversation_type TEXT NOT NULL DEFAULT 'public',
        peer_node_id     TEXT,
        peer_name        TEXT,
        is_read          INTEGER NOT NULL DEFAULT 1,
        delivery_status  TEXT NOT NULL DEFAULT 'sent',
        message_kind     TEXT NOT NULL DEFAULT 'text',
        media_mime_type  TEXT,
        media_byte_length INTEGER,
        media_width      INTEGER,
        media_height     INTEGER,
        media_transfer_id TEXT,
        media_duration_ms INTEGER,
        media_temp_path  TEXT
      )
    ''');
    // Covering index for loadRecent and prune queries.
    // Supports ORDER BY received_at DESC (leftmost prefix) and enables
    // index-only scans for the prune subquery (SELECT id ... ORDER BY received_at).
    await db.execute(
      'CREATE INDEX idx_received_at_id ON $_kTable (received_at DESC, id)',
    );
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE $_kTable ADD COLUMN conversation_type TEXT NOT NULL DEFAULT 'public'",
      );
      await db.execute('ALTER TABLE $_kTable ADD COLUMN peer_node_id TEXT');
      await db.execute('ALTER TABLE $_kTable ADD COLUMN peer_name TEXT');
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE $_kTable ADD COLUMN delivery_status TEXT NOT NULL DEFAULT 'sent'",
      );
    }
    if (oldVersion < 4) {
      // Replace single-column index with covering index for prune query optimization.
      await db.execute('DROP INDEX IF EXISTS idx_received_at');
      await db.execute(
        'CREATE INDEX idx_received_at_id ON $_kTable (received_at DESC, id)',
      );
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE $_kTable ADD COLUMN is_read INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 6) {
      await db.execute(
        "ALTER TABLE $_kTable ADD COLUMN message_kind TEXT NOT NULL DEFAULT 'text'",
      );
      await db.execute('ALTER TABLE $_kTable ADD COLUMN media_mime_type TEXT');
      await db.execute(
        'ALTER TABLE $_kTable ADD COLUMN media_byte_length INTEGER',
      );
      await db.execute('ALTER TABLE $_kTable ADD COLUMN media_width INTEGER');
      await db.execute('ALTER TABLE $_kTable ADD COLUMN media_height INTEGER');
      await db.execute(
        'ALTER TABLE $_kTable ADD COLUMN media_transfer_id TEXT',
      );
      await db.execute('ALTER TABLE $_kTable ADD COLUMN media_temp_path TEXT');
    }
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE $_kTable ADD COLUMN media_duration_ms INTEGER',
      );
    }
  }

  @override
  Future<void> save(AirGridMessage message) async {
    await _db.insert(_kTable, {
      'id': message.id,
      'packet_id': message.id,
      'sender_node_id': message.senderNodeId,
      'sender_name': message.senderName,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'received_at': DateTime.now().millisecondsSinceEpoch,
      'is_local': message.isLocal ? 1 : 0,
      'encryption_state': message.isEncrypted ? 'encrypted' : 'plaintext',
      'conversation_type': message.conversationType,
      'peer_node_id': message.peerNodeId,
      'peer_name': message.peerName,
      'is_read': message.isRead ? 1 : 0,
      'delivery_status': message.deliveryStatus.name,
      'message_kind': message.messageKind,
      'media_mime_type': message.mediaMimeType,
      'media_byte_length': message.mediaByteLength,
      'media_width': message.mediaWidth,
      'media_height': message.mediaHeight,
      'media_transfer_id': message.mediaTransferId,
      'media_duration_ms': message.mediaDurationMs,
      'media_temp_path': message.mediaTempPath,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async {
    final rows = await _db.query(
      _kTable,
      orderBy: 'received_at DESC',
      limit: limit,
    );
    return rows.map(_rowToMessage).toList();
  }

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {
    await _db.update(
      _kTable,
      {'delivery_status': status.name},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  AirGridMessage _rowToMessage(Map<String, dynamic> row) {
    return AirGridMessage(
      id: row['id'] as String,
      senderNodeId: row['sender_node_id'] as String,
      senderName: row['sender_name'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      content: row['content'] as String,
      isLocal: (row['is_local'] as int) == 1,
      isEncrypted: (row['encryption_state'] as String?) == 'encrypted',
      conversationType: row['conversation_type'] as String? ?? 'public',
      peerNodeId: row['peer_node_id'] as String?,
      peerName: row['peer_name'] as String?,
      isRead: (row['is_read'] as int? ?? 1) == 1,
      deliveryStatus: _parseDeliveryStatus(row['delivery_status'] as String?),
      messageKind: row['message_kind'] as String? ?? 'text',
      mediaMimeType: row['media_mime_type'] as String?,
      mediaByteLength: row['media_byte_length'] as int?,
      mediaWidth: row['media_width'] as int?,
      mediaHeight: row['media_height'] as int?,
      mediaTransferId: row['media_transfer_id'] as String?,
      mediaDurationMs: row['media_duration_ms'] as int?,
      mediaTempPath: row['media_temp_path'] as String?,
    );
  }

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {
    await _db.update(
      _kTable,
      {'is_read': 1},
      where: 'conversation_type = ? AND peer_node_id = ? AND is_local = 0',
      whereArgs: ['private', peerNodeId],
    );
  }

  DeliveryStatus _parseDeliveryStatus(String? value) {
    return DeliveryStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => DeliveryStatus.sent,
    );
  }

  Future<void> close() => _db.close();

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async {
    final threshold = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final deleted = await _db.transaction<int>((txn) async {
      // Delete by age first.
      final deletedByAge = await txn.delete(
        _kTable,
        where: 'received_at < ?',
        whereArgs: [threshold],
      );

      // Delete anything outside the newest `maxMessages`.
      // This deletes rows whose id is NOT in the newest `maxMessages` ids.
      final deletedByCount = await txn.rawDelete(
        'DELETE FROM $_kTable WHERE id NOT IN (SELECT id FROM $_kTable ORDER BY received_at DESC LIMIT ?)',
        [maxMessages],
      );

      return deletedByAge + deletedByCount;
    });
    if (deleted > 0) {
      AirGridLogger.log(
        LogCategory.storage,
        'Pruned $deleted message(s); maxMessages=$maxMessages maxAge=${maxAge.inDays}d',
      );
    }
    if (deleted >= _kVacuumDeletedRowsThreshold) {
      await _db.execute('VACUUM');
      AirGridLogger.log(LogCategory.storage, 'Vacuumed after pruning');
    }
    return deleted;
  }

  @override
  Future<void> clearAll() async {
    final deleted = await _db.transaction<int>((txn) async {
      return txn.delete(_kTable);
    });
    AirGridLogger.log(LogCategory.storage, 'Cleared $deleted message(s)');
    if (deleted >= _kVacuumDeletedRowsThreshold) {
      await _db.execute('VACUUM');
      AirGridLogger.log(LogCategory.storage, 'Vacuumed after clear');
    }
  }
}
