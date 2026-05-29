import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';

import 'fake_transport.dart';

/// Decodes all packets recorded in [transport.sentPayloads].
///
/// Returns one [AirGridPacket] per entry in [sentPayloads], regardless of
/// how many endpoint IDs each send targeted.
List<AirGridPacket> decodeSentPackets(FakeTransport transport) {
  return transport.sentPayloads
      .map((p) => TransportCodec.decode(p.bytes))
      .whereType<AirGridPacket>()
      .toList();
}

/// Returns packets from [transport.sentPayloads] entries that included
/// [endpointId] as a destination.
List<AirGridPacket> packetsSentTo(FakeTransport transport, String endpointId) {
  return transport.sentPayloads
      .where((p) => p.endpoints.contains(endpointId))
      .map((p) => TransportCodec.decode(p.bytes))
      .whereType<AirGridPacket>()
      .toList();
}

/// Filters [packets] to only those whose [AirGridPacket.packetType] == [type].
List<AirGridPacket> packetsOfType(List<AirGridPacket> packets, String type) {
  return packets.where((p) => p.packetType == type).toList();
}
