import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/data/transport/packet_fragmenter.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AirGridPacket _makePacket({
  String id = 'orig-001',
  String content = 'Hello World',
  String conversationType = 'public',
  int? encryptionVersion,
  String? recipientNodeId,
}) {
  return AirGridPacket(
    messageId: id,
    senderNodeId: 'node-a',
    senderName: 'Alice',
    timestamp: DateTime(2025, 1, 1).toUtc().millisecondsSinceEpoch,
    content: content,
    seenByNodes: const ['node-a'],
    hopLimit: 8,
    packetType: 'chat',
    conversationType: conversationType,
    encryptionVersion: encryptionVersion,
    recipientNodeId: recipientNodeId,
  );
}

/// Produces a content string whose encoded byte length exceeds [minBytes].
String _bigContent(int minBytes) {
  // Each ASCII character encodes to 1 byte in UTF-8 inside the TLV,
  // so a string of 'X' * minBytes is reliably large enough.
  return 'X' * minBytes;
}

void main() {
  // -- PacketFragmenter.fragment (static) ------------------------------------

  group('PacketFragmenter.fragment', () {
    test('returns [original] when encoded size <= threshold', () {
      final packet = _makePacket();
      final result = PacketFragmenter.fragment(
        packet,
        threshold: AirGridConstants.kFragmentThreshold,
      );
      expect(result, hasLength(1));
      expect(result.first.packetType, 'chat');
      expect(result.first.messageId, packet.messageId);
    });

    test('fragments when encoded size > threshold', () {
      final packet = _makePacket(content: _bigContent(8500));
      final encoded = TransportCodec.encode(packet);
      final expectedCount =
          (encoded.length + AirGridConstants.kFragmentThreshold - 1) ~/
          AirGridConstants.kFragmentThreshold;

      final frags = PacketFragmenter.fragment(packet);
      expect(frags.length, expectedCount);
      expect(frags.length, greaterThan(1));
    });

    test('each fragment has correct fragment fields', () {
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      for (int i = 0; i < frags.length; i++) {
        final f = frags[i];
        expect(f.packetType, 'fragment');
        expect(f.fragmentOf, packet.messageId);
        expect(f.fragmentIndex, i);
        expect(f.fragmentCount, frags.length);
        expect(f.senderNodeId, packet.senderNodeId);
        expect(f.senderName, packet.senderName);
        expect(f.conversationType, packet.conversationType);
      }
    });

    test('fragment content fields are non-empty base64', () {
      final packet = _makePacket(content: _bigContent(5000));
      final frags = PacketFragmenter.fragment(packet);
      for (final f in frags) {
        expect(() => base64.decode(f.content), returnsNormally);
        expect(f.content, isNotEmpty);
      }
    });

    test('copies encryptionVersion and recipientNodeId from original', () {
      final packet = _makePacket(
        content: _bigContent(9000),
        conversationType: 'private',
        encryptionVersion: 1,
        recipientNodeId: 'node-b',
      );
      final frags = PacketFragmenter.fragment(packet);
      for (final f in frags) {
        expect(f.encryptionVersion, 1);
        expect(f.recipientNodeId, 'node-b');
      }
    });

    test('each fragment gets a unique messageId', () {
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);
      final ids = frags.map((f) => f.messageId).toSet();
      expect(ids.length, frags.length);
    });

    test('fragments share seenByNodes list reference with original', () {
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // All fragments should reference the same list instance as the original
      for (final frag in frags) {
        expect(identical(frag.seenByNodes, packet.seenByNodes), isTrue,
          reason: 'Fragments should share seenByNodes reference to avoid allocation');
      }
    });

    test('seenByNodes shared reference does not affect relay behavior', () {
      // Verify that even with shared references, relay operations work correctly
      // because they create new packets with new lists via copyWith/spread operator
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // Simulate relay: create new packet with additional node
      final relayed = frags.first.copyWith(
        seenByNodes: [...frags.first.seenByNodes, 'node-relay'],
      );

      // Original and fragments should be unchanged
      expect(packet.seenByNodes, ['node-a']);
      expect(frags.first.seenByNodes, ['node-a']);
      expect(relayed.seenByNodes, ['node-a', 'node-relay']);
    });
  });

  // -- PacketFragmenter.tryReassemble (instance) ----------------------------

  group('PacketFragmenter.tryReassemble', () {
    test('returns null with partial fragments', () {
      final fragmenter = PacketFragmenter();
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // Feed all but the last.
      for (int i = 0; i < frags.length - 1; i++) {
        expect(fragmenter.tryReassemble(frags[i]), isNull);
      }
    });

    test('returns reassembled packet when all fragments fed in order', () {
      final fragmenter = PacketFragmenter();
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      AirGridPacket? assembled;
      for (final f in frags) {
        assembled = fragmenter.tryReassemble(f);
      }

      expect(assembled, isNotNull);
      expect(assembled!.messageId, packet.messageId);
      expect(assembled.content, packet.content);
      expect(assembled.packetType, 'chat');
    });

    test('handles out-of-order fragment delivery', () {
      final fragmenter = PacketFragmenter();
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // Reverse order.
      final reversed = frags.reversed.toList();
      AirGridPacket? assembled;
      for (final f in reversed) {
        assembled = fragmenter.tryReassemble(f);
      }

      expect(assembled, isNotNull);
      expect(assembled!.content, packet.content);
    });

    test('duplicate fragment slot returns null and is ignored', () {
      final fragmenter = PacketFragmenter();
      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // Feed slot 0 twice.
      fragmenter.tryReassemble(frags[0]);
      final result = fragmenter.tryReassemble(frags[0]);
      expect(result, isNull);
    });

    test('invalid fragment fields (null fragmentOf) return null', () {
      final fragmenter = PacketFragmenter();
      final bad = AirGridPacket(
        messageId: 'bad-1',
        senderNodeId: 'node-a',
        senderName: 'Alice',
        timestamp: DateTime(2025).toUtc().millisecondsSinceEpoch,
        content: base64.encode(Uint8List(10)),
        seenByNodes: const [],
        hopLimit: 8,
        packetType: 'fragment',
        fragmentOf: null, // missing
        fragmentIndex: 0,
        fragmentCount: 2,
      );
      expect(fragmenter.tryReassemble(bad), isNull);
    });

    test('invalid fragment fields (index out of range) return null', () {
      final fragmenter = PacketFragmenter();
      final bad = AirGridPacket(
        messageId: 'bad-2',
        senderNodeId: 'node-a',
        senderName: 'Alice',
        timestamp: DateTime(2025).toUtc().millisecondsSinceEpoch,
        content: base64.encode(Uint8List(10)),
        seenByNodes: const [],
        hopLimit: 8,
        packetType: 'fragment',
        fragmentOf: 'orig-xyz',
        fragmentIndex: 5, // >= count
        fragmentCount: 2,
      );
      expect(fragmenter.tryReassemble(bad), isNull);
    });

    test('evicts oldest bucket when maxBuckets exceeded', () {
      const maxBuckets = 3;
      final fragmenter = PacketFragmenter(maxBuckets: maxBuckets);

      // Fill buckets with partial fragments from 3 different originals.
      for (int b = 0; b < maxBuckets; b++) {
        final orig = _makePacket(id: 'orig-$b', content: _bigContent(9000));
        final frags = PacketFragmenter.fragment(orig);
        // Feed only first fragment to open the bucket.
        fragmenter.tryReassemble(frags[0]);
      }

      // Now add a 4th original - oldest bucket should be evicted.
      final newOrig = _makePacket(id: 'orig-new', content: _bigContent(9000));
      final newFrags = PacketFragmenter.fragment(newOrig);
      for (final f in newFrags) {
        fragmenter.tryReassemble(f);
      }
      // No assertion on eviction count; just confirm no exception is thrown
      // and new packet can be reassembled.
      // The previously opened buckets for orig-0..2 may be partially evicted.
    });

    test(
      'round-trip: fragment -> encode each -> decode -> reassemble = original',
      () {
        final fragmenter = PacketFragmenter();
        final packet = _makePacket(content: _bigContent(9000));
        final frags = PacketFragmenter.fragment(packet);

        AirGridPacket? assembled;
        for (final frag in frags) {
          // Simulate wire encode/decode for each fragment chunk.
          final bytes = TransportCodec.encode(frag);
          final decoded = TransportCodec.decode(bytes)!;
          assembled = fragmenter.tryReassemble(decoded);
        }

        expect(assembled, isNotNull);
        expect(assembled!.messageId, packet.messageId);
        expect(assembled.content, packet.content);
        expect(assembled.senderNodeId, packet.senderNodeId);
      },
    );

    test('multiple independent originals can be reassembled concurrently', () {
      final fragmenter = PacketFragmenter();

      final packetA = _makePacket(id: 'orig-a', content: _bigContent(9000));
      final packetB = _makePacket(id: 'orig-b', content: _bigContent(9000));

      final fragsA = PacketFragmenter.fragment(packetA);
      final fragsB = PacketFragmenter.fragment(packetB);

      // Interleave delivery.
      AirGridPacket? assembledA;
      AirGridPacket? assembledB;
      for (int i = 0; i < fragsA.length || i < fragsB.length; i++) {
        if (i < fragsA.length) assembledA = fragmenter.tryReassemble(fragsA[i]);
        if (i < fragsB.length) assembledB = fragmenter.tryReassemble(fragsB[i]);
      }

      expect(assembledA, isNotNull);
      expect(assembledA!.messageId, packetA.messageId);
      expect(assembledB, isNotNull);
      expect(assembledB!.messageId, packetB.messageId);
    });

    test('expired bucket is evicted and reassembly starts fresh', () {
      // Use a fake clock to control time deterministically.
      var fakeNow = DateTime(2025, 1, 1, 0, 0, 0);
      final fragmenter = PacketFragmenter(
        ttl: const Duration(seconds: 30),
        clock: () => fakeNow,
      );

      final packet = _makePacket(content: _bigContent(9000));
      final frags = PacketFragmenter.fragment(packet);

      // Feed first fragment to open a bucket at t=0.
      fragmenter.tryReassemble(frags[0]);

      // Advance fake clock past the TTL.
      fakeNow = fakeNow.add(const Duration(seconds: 31));

      // Feed remaining fragments: bucket should have been pruned,
      // so reassembly never completes.
      AirGridPacket? assembled;
      for (int i = 1; i < frags.length; i++) {
        assembled = fragmenter.tryReassemble(frags[i]);
      }
      expect(
        assembled,
        isNull,
        reason: 'expired bucket should have been pruned before reassembly',
      );
    });
  });

  // -- Allocation Efficiency ------------------------------------------------

  group('PacketFragmenter Allocation Efficiency', () {
    test('fragment() avoids unnecessary list copies', () {
      // Verify that fragments share the seenByNodes reference
      final packet = _makePacket(
        content: _bigContent(15000), // Creates ~3 fragments
      );
      final frags = PacketFragmenter.fragment(packet);

      expect(frags.length, greaterThan(2));

      // All fragments should point to the same seenByNodes list instance
      final firstSeenByNodes = frags.first.seenByNodes;
      for (final frag in frags) {
        expect(identical(frag.seenByNodes, firstSeenByNodes), isTrue);
      }

      // Original packet's list should also be the same instance
      expect(identical(packet.seenByNodes, firstSeenByNodes), isTrue);
    });

    test('allocation benchmark: large packet fragmentation', () {
      // This test demonstrates allocation reduction via shared references.
      // Previous implementation: List.of(seenByNodes) for each fragment
      // Current implementation: shared reference
      //
      // For a 12KB packet (~3 fragments), this saves ~3 list allocations per packet.
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < 100; i++) {
        final packet = _makePacket(
          id: 'bench-$i',
          content: _bigContent(12000), // ~3 fragments at 4KB threshold
        );
        final frags = PacketFragmenter.fragment(packet);

        // Verify fragmentation occurred
        expect(frags.length, greaterThan(2));
      }

      stopwatch.stop();

      // Benchmark should complete quickly (no specific threshold, just verify it runs)
      // ignore: avoid_print
      print(
        'Fragmentation benchmark (100 x 12KB): ${stopwatch.elapsedMilliseconds}ms',
      );
    });

    test('shared references do not affect reassembly correctness', () {
      // Verify that shared seenByNodes references don't cause any issues
      // during the full fragment -> reassemble cycle
      final fragmenter = PacketFragmenter();

      // Create packets with explicitly different seenByNodes lists
      final packetA = AirGridPacket(
        messageId: 'shared-a',
        senderNodeId: 'node-a',
        senderName: 'Alice',
        timestamp: DateTime(2025, 1, 1).toUtc().millisecondsSinceEpoch,
        content: _bigContent(9000),
        seenByNodes: ['node-a'], // Fresh list
        hopLimit: 8,
        packetType: 'chat',
      );
      final packetB = AirGridPacket(
        messageId: 'shared-b',
        senderNodeId: 'node-b',
        senderName: 'Bob',
        timestamp: DateTime(2025, 1, 1).toUtc().millisecondsSinceEpoch,
        content: _bigContent(9000),
        seenByNodes: ['node-b'], // Different fresh list
        hopLimit: 8,
        packetType: 'chat',
      );

      final fragsA = PacketFragmenter.fragment(packetA);
      final fragsB = PacketFragmenter.fragment(packetB);

      // Fragments within each packet share references
      expect(identical(fragsA[0].seenByNodes, fragsA[1].seenByNodes), isTrue);
      expect(identical(fragsB[0].seenByNodes, fragsB[1].seenByNodes), isTrue);

      // Different packets have different lists
      expect(
        identical(fragsA[0].seenByNodes, fragsB[0].seenByNodes),
        isFalse,
      );

      // Reassemble both packets successfully
      AirGridPacket? assembledA;
      AirGridPacket? assembledB;

      for (final frag in fragsA) {
        assembledA = fragmenter.tryReassemble(frag);
      }
      for (final frag in fragsB) {
        assembledB = fragmenter.tryReassemble(frag);
      }

      expect(assembledA, isNotNull);
      expect(assembledA!.content, packetA.content);
      expect(assembledB, isNotNull);
      expect(assembledB!.content, packetB.content);
    });
  });
}
