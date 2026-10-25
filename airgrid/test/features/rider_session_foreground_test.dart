import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_harness.dart';

/// A Rider session shares one Android foreground service with the mesh.
///
/// Ending the ride must hand that service back to the mesh, never stop it,
/// and a ride in progress must survive the app leaving and re-entering the
/// screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LifecycleHarness h;

  setUp(() async {
    h = await LifecycleHarness.create(batteryOptimizationEnabled: true);
    await h.startMeshWithPeer();
  });

  tearDown(() => h.dispose());

  Future<void> startRide() async {
    final peer = h.container.read(chatControllerProvider).peers.single;
    await h.rider.startSession(peer);
    await h.settle();
  }

  int riderControlPacketsSent() => h.transport.sentPayloads
      .where((p) => p.endpoints.contains(LifecycleHarness.peerEndpointId))
      .map((p) => TransportCodec.decode(p.bytes))
      .where((p) => p?.packetType == 'rider_control')
      .length;

  test('a ride promotes the mesh service and captures audio', () async {
    await startRide();

    final state = h.container.read(riderModeControllerProvider);
    expect(state.isActive, isTrue);
    expect(state.peerNodeId, h.peerNodeId);
    expect(h.foreground.riderStartCount, 1);
    expect(h.recorder.recording, isTrue);
  });

  test('ending a ride hands the service back to the mesh', () async {
    await startRide();
    final meshStartsBefore = h.foreground.startCount;

    await h.rider.endSession();

    final rider = h.container.read(riderModeControllerProvider);
    expect(rider.isActive, isFalse);
    expect(h.recorder.recording, isFalse);
    expect(
      h.foreground.stopCount,
      0,
      reason: 'the mesh foreground service must keep running after a ride',
    );
    expect(
      h.foreground.riderStopCount,
      0,
      reason: 'a bare rider stop is what used to kill the service',
    );
    expect(
      h.foreground.startCount,
      meshStartsBefore + 1,
      reason: 'the service is re-promoted as the plain mesh service',
    );
    expect(h.container.read(chatControllerProvider).meshStarted, isTrue);
  });

  test(
    'ending a ride with the mesh already stopped stops the service',
    () async {
      await startRide();
      await h.chat.stopMesh();
      final stopsBefore = h.foreground.stopCount;

      await h.rider.endSession();

      expect(h.foreground.riderStopCount, 1);
      expect(h.foreground.stopCount, stopsBefore);
    },
  );

  test('a refused promotion aborts the ride and tells the peer', () async {
    h.foreground.riderStartSucceeds = false;
    final controlBefore = riderControlPacketsSent();

    await startRide();

    final state = h.container.read(riderModeControllerProvider);
    expect(state.isActive, isFalse);
    expect(state.isStarting, isFalse);
    expect(state.peerNodeId, isNull);
    expect(state.lastError, contains('Open AirGrid'));
    expect(h.recorder.recording, isFalse);
    // Invite, then the end notice: the peer accepted an invite that never
    // became a session and must not be left talking to nobody.
    expect(riderControlPacketsSent(), controlBefore + 2);
    expect(h.foreground.stopCount, 0);
  });

  test('a ride survives the app going to the background and back', () async {
    await startRide();
    final transportStops = h.transport.stopCount;
    final meshServiceStops = h.foreground.stopCount;

    // Battery optimisation is on, which stops the mesh on pause for an idle
    // app; a live ride must hold it open.
    await h.chat.handleAppLifecycleState(AppLifecycleState.paused);
    await h.chat.handleAppLifecycleState(AppLifecycleState.resumed);
    await h.settle();

    final rider = h.container.read(riderModeControllerProvider);
    final chat = h.container.read(chatControllerProvider);
    expect(rider.isActive, isTrue);
    expect(chat.meshStarted, isTrue);
    expect(chat.peers.map((p) => p.nodeId), [h.peerNodeId]);
    expect(h.transport.stopCount, transportStops);
    expect(h.foreground.stopCount, meshServiceStops);

    await h.rider.endSession();
  });

  test('after a ride ends the battery-saver pause works again', () async {
    await startRide();
    await h.rider.endSession();

    await h.chat.handleAppLifecycleState(AppLifecycleState.paused);

    expect(h.container.read(chatControllerProvider).meshStarted, isFalse);
  });
}
