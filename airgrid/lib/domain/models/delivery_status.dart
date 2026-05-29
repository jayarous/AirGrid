/// Delivery status for outgoing private direct messages.
///
/// Status indicators are only shown for local (outgoing) private messages.
/// Public mesh messages do not participate in this model.
enum DeliveryStatus {
  /// Message created locally; transport send not yet confirmed.
  pending,

  /// Payload was handed to the transport API successfully.
  sent,

  /// Recipient app accepted and processed the packet.
  delivered,

  /// Recipient opened the private thread.
  read,

  /// Transport or encoding failure; message was not delivered.
  failed,
}

/// Returns `true` if transitioning from [current] to [next] is a valid
/// status advancement.
///
/// Rules:
/// - [DeliveryStatus.read] and [DeliveryStatus.failed] are terminal states.
/// - [DeliveryStatus.failed] may only come from [DeliveryStatus.pending].
/// - Otherwise the status must advance strictly: pending → sent → delivered → read.
bool canAdvanceStatus(DeliveryStatus current, DeliveryStatus next) {
  if (current == DeliveryStatus.read || current == DeliveryStatus.failed) {
    return false;
  }
  if (next == DeliveryStatus.failed) {
    return current == DeliveryStatus.pending;
  }
  const order = [
    DeliveryStatus.pending,
    DeliveryStatus.sent,
    DeliveryStatus.delivered,
    DeliveryStatus.read,
  ];
  return order.indexOf(next) > order.indexOf(current);
}
