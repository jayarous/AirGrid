import 'dart:typed_data';

import 'package:airgrid/data/transport/transport_event.dart';

/// Transport-agnostic interface.
///
/// The mesh routing engine ([AirGridMeshService]) depends ONLY on this
/// interface.  All Android Nearby Connections specifics live in
/// [NearbyConnectionsTransport].  Future transports (iOS Multipeer, BLE-only,
/// Wi-Fi Aware) implement this contract without touching the mesh layer.
abstract interface class TransportService {
  /// Stream of lifecycle and data events emitted by the transport layer.
  Stream<TransportEvent> get events;

  /// Currently connected endpoint IDs (read-only snapshot).
  Set<String> get connectedEndpoints;

  /// Begin advertising and discovering under [nodeId] / [displayName].
  Future<void> start(String nodeId, String displayName);

  /// Begin advertising this device to nearby peers.
  Future<void> startAdvertising();

  /// Stop advertising this device while leaving discovery/connections alone.
  Future<void> stopAdvertising();

  /// Begin discovering nearby peers.
  Future<void> startDiscovery();

  /// Stop discovering nearby peers while leaving advertising/connections alone.
  Future<void> stopDiscovery();

  /// Send [bytes] to every endpoint listed in [endpointIds].
  ///
  /// The mesh service controls exactly which endpoints receive a packet
  /// (e.g. excluding the source endpoint to reduce pointless traffic).
  Future<void> sendToEndpoints(Iterable<String> endpointIds, Uint8List bytes);

  /// Stop all connections and shut down the transport.
  Future<void> stop();
}
