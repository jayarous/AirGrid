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
  int startCount = 0;
  int stopCount = 0;

  @override
  Stream<void> get exitRequests => _exitController.stream;

  @override
  Future<bool> consumePendingExitAction() async => false;

  @override
  Future<void> showPrivateMessageNotification(String senderName) async {}

  @override
  Future<void> startMeshService() async {
    startCount++;
  }

  @override
  Future<void> stopMeshService() async {
    stopCount++;
  }

  Future<void> dispose() => _exitController.close();
}
