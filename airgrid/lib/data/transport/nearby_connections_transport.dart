import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/logger.dart';
import 'package:airgrid/data/transport/transport_event.dart';
import 'package:airgrid/domain/services/transport_service.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Thrown when Nearby Connections cannot start all required subsystems.
class TransportStartException implements Exception {
  final String reason;

  const TransportStartException(this.reason);

  @override
  String toString() => 'TransportStartException: $reason';
}

/// Android implementation of [TransportService] using the Nearby Connections
/// API (strategy: [Strategy.P2P_CLUSTER]).
///
/// This is the only file in the project that imports nearby_connections.
/// The mesh engine and UI layers are fully isolated from this dependency.
///
/// Both advertising and discovery are started simultaneously so every device
/// can act as both advertiser and discoverer, enabling mesh topology.
class NearbyConnectionsTransport implements TransportService {
  final _eventController = StreamController<TransportEvent>.broadcast();
  final Set<String> _connectedEndpoints = {};

  /// Stores the display name reported by the remote end during connection
  /// initiation, keyed by endpointId.
  final Map<String, String> _pendingNames = {};
  final Map<String, String> _pendingNodeIds = {};

  /// Guards Nearby callbacks after stop().
  bool _isRunning = false;

  String _nodeId = '';
  String _advertisedName = '';

  @override
  Stream<TransportEvent> get events => _eventController.stream;

  @override
  Set<String> get connectedEndpoints => Set.unmodifiable(_connectedEndpoints);

  @override
  Future<void> start(String nodeId, String displayName) async {
    // Clean up any lingering session from a previous start/stop cycle.
    try {
      await Nearby().stopAdvertising();
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop advertising during cleanup: $e',
      );
    }
    try {
      await Nearby().stopDiscovery();
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop discovery during cleanup: $e',
      );
    }

    _nodeId = nodeId;
    _advertisedName = _encodeEndpointName(nodeId, displayName);
    _isRunning = true;

    try {
      await _startAdvertising();
      await _startDiscovery();
    } on TransportStartException {
      await stop();
      rethrow;
    } catch (e) {
      await stop();
      final exception = TransportStartException(e.toString());
      _eventController.add(TransportStartFailed(exception.reason));
      throw exception;
    }
  }

  @override
  Future<void> startAdvertising() async {
    if (!_isRunning) return;
    await _startAdvertising();
  }

  @override
  Future<void> stopAdvertising() async {
    try {
      await Nearby().stopAdvertising();
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop advertising: $e',
      );
    }
  }

  @override
  Future<void> startDiscovery() async {
    if (!_isRunning) return;
    await _startDiscovery();
  }

  @override
  Future<void> stopDiscovery() async {
    try {
      await Nearby().stopDiscovery();
    } catch (e) {
      AirGridLogger.log(LogCategory.connection, 'Failed to stop discovery: $e');
    }
  }

  @override
  Future<void> sendToEndpoints(
    Iterable<String> endpointIds,
    Uint8List bytes,
  ) async {
    for (final id in endpointIds) {
      try {
        await Nearby().sendBytesPayload(id, bytes);
      } catch (e) {
        AirGridLogger.log(
          LogCategory.routing,
          'sendBytesPayload failed to $id: $e',
        );
      }
    }
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    await stopAdvertising();
    await stopDiscovery();
    try {
      await Nearby().stopAllEndpoints();
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop all endpoints: $e',
      );
    }
    _connectedEndpoints.clear();
    _pendingNames.clear();
    _pendingNodeIds.clear();
    AirGridLogger.log(LogCategory.connection, 'Transport stopped');
  }

  Future<void> _startAdvertising() async {
    try {
      await Nearby().startAdvertising(
        _advertisedName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: AirGridConstants.kServiceId,
      );
      AirGridLogger.log(LogCategory.advertising, 'Advertising started');
    } catch (e) {
      AirGridLogger.log(LogCategory.advertising, 'Advertising failed: $e');
      _eventController.add(TransportStartFailed(e.toString()));
      throw TransportStartException(e.toString());
    }
  }

  Future<void> _startDiscovery() async {
    try {
      await Nearby().startDiscovery(
        _advertisedName,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: AirGridConstants.kServiceId,
      );
      AirGridLogger.log(LogCategory.discovery, 'Discovery started');
    } catch (e) {
      AirGridLogger.log(LogCategory.discovery, 'Discovery failed: $e');
      _eventController.add(TransportStartFailed(e.toString()));
      throw TransportStartException(e.toString());
    }
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    if (!_isRunning) return;

    final remote = _decodeEndpointName(name);
    final remoteNodeId = remote.nodeId;
    final remoteDisplayName = remote.displayName;

    if (remoteNodeId == _nodeId) {
      AirGridLogger.log(
        LogCategory.discovery,
        'Endpoint found: $id ($remoteDisplayName) - same node, skipping',
      );
      return;
    }

    if (_connectedEndpoints.contains(id) || _pendingNames.containsKey(id)) {
      AirGridLogger.log(
        LogCategory.discovery,
        'Endpoint found: $id ($remoteDisplayName) - already pending/connected, skipping',
      );
      return;
    }

    // Both phones advertise and discover. Elect one requester so two devices
    // do not collide with simultaneous requestConnection calls.
    if (remoteNodeId != null && _nodeId.compareTo(remoteNodeId) > 0) {
      AirGridLogger.log(
        LogCategory.discovery,
        'Endpoint found: $id ($remoteDisplayName) - waiting for peer to initiate',
      );
      return;
    }

    _pendingNames[id] = remoteDisplayName;
    if (remoteNodeId != null) {
      _pendingNodeIds[id] = remoteNodeId;
    }
    AirGridLogger.log(
      LogCategory.discovery,
      'Endpoint found: $id ($remoteDisplayName) - requesting connection',
    );
    _requestConnectionSafe(id);
  }

  Future<void> _requestConnectionSafe(String id) async {
    if (!_isRunning) return;

    // Keep a small jitter for repeated discovery callbacks and older peers
    // that do not advertise node ids.
    final delay = Random().nextInt(500);
    await Future<void>.delayed(Duration(milliseconds: delay));
    if (!_isRunning) return;

    try {
      await Nearby().requestConnection(
        _advertisedName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'requestConnection to $id failed: $e',
      );
      _pendingNames.remove(id);
      _pendingNodeIds.remove(id);
    }
  }

  void _onEndpointLost(String? id) {
    AirGridLogger.log(LogCategory.discovery, 'Endpoint lost: $id');
  }

  /// Called on both the advertiser side and the discoverer side.
  /// Both must call [acceptConnection] to complete the handshake.
  void _onConnectionInitiated(String id, ConnectionInfo info) {
    final remote = _decodeEndpointName(info.endpointName);
    if (!_isRunning) {
      AirGridLogger.log(
        LogCategory.connection,
        'Connection initiated: $id - transport stopped, ignoring',
      );
      return;
    }

    AirGridLogger.log(
      LogCategory.connection,
      'Connection initiated: $id (${remote.displayName})',
    );
    _pendingNames[id] = remote.displayName;
    if (remote.nodeId != null) {
      _pendingNodeIds[id] = remote.nodeId!;
    }
    _acceptConnectionSafe(id);
  }

  Future<void> _acceptConnectionSafe(String id) async {
    if (!_isRunning) return;
    try {
      await Nearby().acceptConnection(
        id,
        onPayLoadRecieved: _onPayloadReceived,
      );
    } catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'acceptConnection for $id failed: $e',
      );
    }
  }

  void _onConnectionResult(String id, Status status) {
    if (status == Status.CONNECTED) {
      final name = _pendingNames.remove(id) ?? '';
      final nodeId = _pendingNodeIds.remove(id);
      _connectedEndpoints.add(id);
      AirGridLogger.log(
        LogCategory.connection,
        'Connected: $id ($name${nodeId != null ? ", $nodeId" : ""})',
      );
      _eventController.add(TransportPeerConnected(id, name, nodeId: nodeId));
    } else {
      _pendingNames.remove(id);
      _pendingNodeIds.remove(id);
      AirGridLogger.log(
        LogCategory.connection,
        'Connection result: $id status=$status',
      );
    }
  }

  void _onDisconnected(String id) {
    _connectedEndpoints.remove(id);
    _pendingNames.remove(id);
    _pendingNodeIds.remove(id);
    AirGridLogger.log(LogCategory.connection, 'Disconnected: $id');
    _eventController.add(TransportPeerDisconnected(id));
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final bytes = payload.bytes;
      if (bytes != null) {
        _eventController.add(TransportBytesReceived(endpointId, bytes));
      }
    }
  }

  String _encodeEndpointName(String nodeId, String displayName) {
    return '$nodeId|$displayName';
  }

  ({String? nodeId, String displayName}) _decodeEndpointName(String value) {
    final separator = value.indexOf('|');
    if (separator <= 0) {
      return (nodeId: null, displayName: value);
    }

    final nodeId = value.substring(0, separator);
    final displayName = value.substring(separator + 1);
    return (nodeId: nodeId.isEmpty ? null : nodeId, displayName: displayName);
  }
}
