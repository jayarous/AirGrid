import 'dart:typed_data';

/// Sealed hierarchy of events emitted by a [TransportService].
///
/// The mesh service uses pattern matching to handle each case.
sealed class TransportEvent {}

/// A new peer has connected and the handshake is complete.
final class TransportPeerConnected extends TransportEvent {
  final String endpointId;
  final String displayName;
  final String? nodeId;

  TransportPeerConnected(this.endpointId, this.displayName, {this.nodeId});

  @override
  String toString() =>
      'TransportPeerConnected(endpoint=$endpointId, name=$displayName, nodeId=$nodeId)';
}

/// A previously-connected peer has disconnected.
final class TransportPeerDisconnected extends TransportEvent {
  final String endpointId;

  TransportPeerDisconnected(this.endpointId);

  @override
  String toString() => 'TransportPeerDisconnected(endpoint=$endpointId)';
}

/// Raw bytes received from a connected peer.
final class TransportBytesReceived extends TransportEvent {
  final String fromEndpointId;
  final Uint8List bytes;

  TransportBytesReceived(this.fromEndpointId, this.bytes);

  @override
  String toString() =>
      'TransportBytesReceived(from=$fromEndpointId, size=${bytes.length})';
}

/// The transport failed to start — typically missing Google Play Services.
final class TransportStartFailed extends TransportEvent {
  final String reason;

  TransportStartFailed(this.reason);

  @override
  String toString() => 'TransportStartFailed(reason=$reason)';
}
