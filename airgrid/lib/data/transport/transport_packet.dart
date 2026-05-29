import 'dart:typed_data';

/// Thin wrapper pairing a raw byte payload with the endpoint it came from
/// (or is destined for).
class TransportPacket {
  final String endpointId;
  final Uint8List bytes;

  const TransportPacket({required this.endpointId, required this.bytes});
}
