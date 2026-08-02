import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/features/profile/peer_profile_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The safety number is the only user-facing defence against impersonation,
/// since node IDs are not cryptographically bound to keys.
Future<void> _showSheet(
  WidgetTester tester,
  PeerProfileSnapshot profile,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showPeerProfileSheet(context, profile),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final key = base64Encode(Uint8List(32)..fillRange(0, 32, 9));

  testWidgets('shows the safety number when a key is known', (tester) async {
    await _showSheet(
      tester,
      PeerProfileSnapshot(
        displayName: 'Alex',
        nodeId: 'node-1',
        isOnline: true,
        publicKeyBase64: key,
      ),
    );

    final expected = await CryptoService.fingerprint(key);

    expect(find.text('Safety number'), findsOneWidget);
    expect(find.text(expected!), findsOneWidget);
  });

  testWidgets('omits the safety number when no key is known', (tester) async {
    await _showSheet(
      tester,
      const PeerProfileSnapshot(
        displayName: 'Alex',
        nodeId: 'node-1',
        isOnline: true,
      ),
    );

    expect(find.text('Safety number'), findsNothing);
    expect(find.text('Alex'), findsOneWidget);
  });

  testWidgets('two different keys render different safety numbers', (
    tester,
  ) async {
    final other = base64Encode(Uint8List(32)..fillRange(0, 32, 4));

    final a = await CryptoService.fingerprint(key);
    final b = await CryptoService.fingerprint(other);

    expect(a, isNot(b));

    await _showSheet(
      tester,
      PeerProfileSnapshot(
        displayName: 'Alex',
        nodeId: 'node-1',
        isOnline: true,
        publicKeyBase64: other,
      ),
    );

    expect(find.text(b!), findsOneWidget);
    expect(find.text(a!), findsNothing);
  });
}
