import 'dart:async';
import 'dart:typed_data';

import 'package:airgrid/data/transport/nearby_connections_transport.dart';
import 'package:airgrid/data/transport/transport_event.dart';
import 'package:airgrid/domain/services/transport_service.dart';

/// In-memory [TransportService] for unit testing.
///
/// Allows tests to:
/// - inject [TransportEvent]s via [injectEvent]
/// - inspect outbound byte payloads via [sentPayloads]
class FakeTransport implements TransportService {
  final _controller = StreamController<TransportEvent>.broadcast();
  final Set<String> _endpoints = {};
  bool failStart = false;
  int startCount = 0;
  int stopCount = 0;
  int startAdvertisingCount = 0;
  int stopAdvertisingCount = 0;
  int startDiscoveryCount = 0;
  int stopDiscoveryCount = 0;

  /// All (endpointIds, bytes) pairs sent via [sendToEndpoints].
  final List<({List<String> endpoints, Uint8List bytes})> sentPayloads = [];

  @override
  Stream<TransportEvent> get events => _controller.stream;

  @override
  Set<String> get connectedEndpoints => Set.unmodifiable(_endpoints);

  @override
  Future<void> start(String nodeId, String displayName) async {
    startCount++;
    if (failStart) {
      throw const TransportStartException('Fake transport start failed');
    }
  }

  @override
  Future<void> startAdvertising() async {
    startAdvertisingCount++;
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCount++;
  }

  @override
  Future<void> startDiscovery() async {
    startDiscoveryCount++;
  }

  @override
  Future<void> stopDiscovery() async {
    stopDiscoveryCount++;
  }

  @override
  Future<void> sendToEndpoints(
    Iterable<String> endpointIds,
    Uint8List bytes,
  ) async {
    sentPayloads.add((endpoints: endpointIds.toList(), bytes: bytes));
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _endpoints.clear();
  }

  /// Add an endpoint to the connected set and fire a [TransportPeerConnected].
  void connectPeer(
    String endpointId, {
    String name = 'TestPeer',
    String? nodeId,
  }) {
    _endpoints.add(endpointId);
    _controller.add(TransportPeerConnected(endpointId, name, nodeId: nodeId));
  }

  /// Remove an endpoint and fire a [TransportPeerDisconnected].
  void disconnectPeer(String endpointId) {
    _endpoints.remove(endpointId);
    _controller.add(TransportPeerDisconnected(endpointId));
  }

  /// Deliver raw bytes as if received from [fromEndpointId].
  void receiveBytes(String fromEndpointId, Uint8List bytes) {
    _controller.add(TransportBytesReceived(fromEndpointId, bytes));
  }

  void dispose() => _controller.close();
}
