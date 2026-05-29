import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';

/// Persistence contract for chat messages.
abstract interface class MessageRepository {
  /// Persist [message]. Duplicate saves (same [AirGridMessage.id]) are
  /// silently ignored, making this method safe to call more than once.
  Future<void> save(AirGridMessage message);

  /// Returns up to [limit] messages ordered by receive time, newest first.
  Future<List<AirGridMessage>> loadRecent({int limit = 1000});

  /// Updates the [deliveryStatus] of the stored message identified by
  /// [messageId]. No-op if no such message exists.
  Future<void> updateStatus(String messageId, DeliveryStatus status);

  /// Marks all incoming private messages from [peerNodeId] as read.
  Future<void> markPrivateThreadRead(String peerNodeId);

  /// Delete messages older than [maxAge] and trim to at most [maxMessages].
  /// Returns the number of rows deleted.
  Future<int> prune({required int maxMessages, required Duration maxAge});

  /// Remove all persisted messages. Implementations may perform maintenance
  /// such as `VACUUM` after clearing storage.
  Future<void> clearAll();
}
