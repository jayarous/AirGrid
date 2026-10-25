import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_harness.dart';

/// Returning to the foreground must not tear the mesh down.
///
/// Resume fires for pulling down the notification shade or answering a
/// permission dialog. A forced transport restart there clears the peer list,
/// which every live walkie or Rider session reads as "peer lost".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LifecycleHarness h;

  setUp(() async {
    h = await LifecycleHarness.create();
  });

  tearDown(() => h.dispose());

  Future<void> resume() =>
      h.chat.handleAppLifecycleState(AppLifecycleState.resumed);

  test('a resume with a connected peer leaves the transport alone', () async {
    await h.startMeshWithPeer();
    final stopsBefore = h.transport.stopCount;
    final startsBefore = h.transport.startCount;

    await resume();
    await h.settle();

    final state = h.container.read(chatControllerProvider);
    expect(h.transport.stopCount, stopsBefore);
    expect(h.transport.startCount, startsBefore);
    expect(state.peers.map((p) => p.nodeId), [h.peerNodeId]);
    expect(state.meshStarted, isTrue);
  });

  test('a resume with no peers still restarts the transport', () async {
    // Nothing to lose and the transport may genuinely have died while the
    // app was away, so the old behaviour stays for this case.
    await h.chat.startMesh();
    final stopsBefore = h.transport.stopCount;
    final startsBefore = h.transport.startCount;

    await resume();

    expect(h.transport.stopCount, stopsBefore + 1);
    expect(h.transport.startCount, startsBefore + 1);
    expect(h.container.read(chatControllerProvider).meshStarted, isTrue);
  });

  test('a resume during a foreground action leaves the mesh alone', () async {
    await h.chat.startMesh();
    h.chat.beginForegroundCriticalAction();
    final stopsBefore = h.transport.stopCount;

    await resume();

    expect(h.transport.stopCount, stopsBefore);
    h.chat.endForegroundCriticalAction();
  });

  test('a resume still honours an Exit tapped on the notification', () async {
    await h.startMeshWithPeer();
    h.foreground.pendingExitAction = true;

    await resume();

    final state = h.container.read(chatControllerProvider);
    expect(state.meshStarted, isFalse);
    expect(h.foreground.stopCount, 1);
  });

  test('a resume with the mesh stopped does nothing', () async {
    await resume();

    expect(h.transport.startCount, 0);
    expect(h.foreground.startCount, 0);
  });
}
