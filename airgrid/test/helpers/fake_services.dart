import 'dart:async';

import 'package:airgrid/core/foreground_service_bridge.dart';
import 'package:airgrid/core/play_services_bridge.dart';

class FakePlayServices implements PlayServicesAvailability {
  PlayServicesStatus status;

  FakePlayServices(this.status);

  @override
  Future<PlayServicesStatus> checkAvailability() async => status;

  @override
  Future<bool> resolve(PlayServicesStatus status) async => status.canResolve;
}

class FakeForegroundService implements MeshForegroundService {
  final _exitController = StreamController<void>.broadcast();
  final _riderMuteController = StreamController<void>.broadcast();
  final _riderEndController = StreamController<void>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  int riderStartCount = 0;
  int riderStopCount = 0;
  bool riderMuted = false;

  @override
  Stream<void> get exitRequests => _exitController.stream;

  @override
  Stream<void> get riderMuteRequests => _riderMuteController.stream;

  @override
  Stream<void> get riderEndRequests => _riderEndController.stream;

  @override
  Future<bool> consumePendingExitAction() async => false;

  @override
  Future<PrivateMessageNotificationTap?>
  consumePendingPrivateMessageTap() async => null;

  @override
  Stream<PrivateMessageNotificationTap> get privateMessageNotificationTaps =>
      const Stream.empty();

  @override
  Future<void> showPrivateMessageNotification({
    required String peerNodeId,
    required String senderName,
  }) async {}

  @override
  Future<void> startMeshService() async {
    startCount++;
  }

  @override
  Future<void> startRiderService({
    required String peerName,
    required bool muted,
  }) async {
    riderStartCount++;
    riderMuted = muted;
  }

  @override
  Future<void> updateRiderServiceMuted(bool muted) async {
    riderMuted = muted;
  }

  @override
  Future<void> stopMeshService() async {
    stopCount++;
  }

  @override
  Future<void> stopRiderService() async {
    riderStopCount++;
  }

  Future<void> dispose() async {
    await _exitController.close();
    await _riderMuteController.close();
    await _riderEndController.close();
  }
}
