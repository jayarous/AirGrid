import 'package:airgrid/core/validation.dart';

/// Immutable type-safe node identifier.
///
/// Node IDs must be valid UUID v4 strings. This wrapper provides compile-time
/// type safety to prevent mixing node IDs with other string identifiers.
///
/// Use [NodeId.fromString] to parse and validate a node ID string, or
/// [NodeId.fromValidated] when the string is already known to be valid.
class NodeId {
  final String value;

  const NodeId._(this.value);

  /// Creates a [NodeId] from a validated UUID string.
  ///
  /// The caller guarantees [value] is a valid UUID. Use this when you've
  /// already validated the string or are constructing from a trusted source.
  const NodeId.fromValidated(this.value);

  /// Parses and validates a node ID string.
  ///
  /// Returns a [NodeId] if [str] is a valid UUID, otherwise returns null.
  static NodeId? fromString(String str) {
    if (!NodeIdValidator.isValid(str)) {
      return null;
    }
    return NodeId._(str);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeId &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Immutable type-safe endpoint identifier.
///
/// Endpoint IDs are transport-assigned identifiers for connected peers.
/// They are not UUIDs and validation is intentionally permissive.
///
/// Use [EndpointId.fromString] to create an endpoint ID from a transport-provided
/// string.
class EndpointId {
  final String value;

  const EndpointId._(this.value);

  /// Creates an [EndpointId] from a transport-provided string.
  ///
  /// Endpoint IDs must be non-empty. Returns null if [str] is empty.
  static EndpointId? fromString(String str) {
    if (str.isEmpty) {
      return null;
    }
    return EndpointId._(str);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EndpointId &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Immutable type-safe message identifier.
///
/// Message IDs are typically UUID v4 strings but legacy or test code may
/// use other formats. Validation accepts any non-empty string.
///
/// Use [MessageId.fromString] to create a message ID from any valid string.
class MessageId {
  final String value;

  const MessageId._(this.value);

  /// Creates a [MessageId] from a string.
  ///
  /// Message IDs must be non-empty. Returns null if [str] is empty.
  /// Accepts UUID strings as well as legacy or test identifiers.
  static MessageId? fromString(String str) {
    if (str.isEmpty) {
      return null;
    }
    return MessageId._(str);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageId &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
