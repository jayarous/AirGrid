import 'package:airgrid/core/lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LruCache', () {
    group('Basic Operations', () {
      test('starts empty', () {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(seconds: 60),
        );
        expect(cache.length, 0);
        expect(cache.contains('key1'), false);
      });

      test('add and contains work for fresh entries', () {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        expect(cache.contains('key1'), true);
        expect(cache.length, 1);
      });

      test('add refreshes existing entry', () {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        cache.add('key2');
        cache.add('key1'); // Refresh
        expect(cache.length, 2);
        expect(cache.contains('key1'), true);
        expect(cache.contains('key2'), true);
      });
    });

    group('LRU Eviction (maxSize)', () {
      test('evicts oldest entry when maxSize exceeded', () {
        final cache = LruCache<String>(
          maxSize: 3,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        cache.add('key2');
        cache.add('key3');
        cache.add('key4'); // Should evict key1

        expect(cache.length, 3);
        expect(cache.contains('key1'), false);
        expect(cache.contains('key2'), true);
        expect(cache.contains('key3'), true);
        expect(cache.contains('key4'), true);
      });

      test('refreshing entry moves it to back (avoids eviction)', () {
        final cache = LruCache<String>(
          maxSize: 3,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        cache.add('key2');
        cache.add('key3');
        cache.add('key1'); // Refresh key1 (moves to back)
        cache.add('key4'); // Should evict key2 (oldest)

        expect(cache.length, 3);
        expect(cache.contains('key1'), true); // Survived because refreshed
        expect(cache.contains('key2'), false); // Evicted (was oldest)
        expect(cache.contains('key3'), true);
        expect(cache.contains('key4'), true);
      });
    });

    group('TTL Expiration', () {
      test('expired entries return false from contains', () async {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(milliseconds: 100),
        );
        cache.add('key1');
        expect(cache.contains('key1'), true);

        await Future.delayed(const Duration(milliseconds: 150));
        expect(cache.contains('key1'), false);
      });

      test('expired entries are removed from cache', () async {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(milliseconds: 100),
        );
        cache.add('key1');
        cache.add('key2');
        expect(cache.length, 2);

        await Future.delayed(const Duration(milliseconds: 150));
        cache.prune(); // Explicit prune triggers cleanup
        expect(cache.length, 0); // Both expired
      });

      test('only expired entries are removed', () async {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(milliseconds: 100),
        );
        cache.add('key1');
        await Future.delayed(const Duration(milliseconds: 60));
        cache.add('key2'); // Added 60ms later
        await Future.delayed(const Duration(milliseconds: 60));

        // key1 is 120ms old (expired), key2 is 60ms old (not expired)
        cache.prune(); // Explicit prune triggers cleanup
        expect(cache.length, 1);
        expect(cache.contains('key2'), true);
      });

      test('prune explicitly removes expired entries', () async {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(milliseconds: 100),
        );
        cache.add('key1');
        cache.add('key2');

        await Future.delayed(const Duration(milliseconds: 150));
        cache.prune();
        expect(cache.length, 0);
      });
    });

    group('Mixed LRU + TTL', () {
      test('LRU eviction happens before TTL expiration', () async {
        final cache = LruCache<String>(
          maxSize: 2,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        cache.add('key2');
        cache.add('key3'); // Should evict key1 due to LRU, not TTL

        expect(cache.length, 2);
        expect(cache.contains('key1'), false);
        expect(cache.contains('key2'), true);
        expect(cache.contains('key3'), true);
      });

      test('TTL expiration works alongside LRU eviction', () async {
        final cache = LruCache<String>(
          maxSize: 3,
          ttl: const Duration(milliseconds: 100),
        );
        cache.add('key1');
        cache.add('key2');
        await Future.delayed(const Duration(milliseconds: 150));
        cache.add('key3'); // key1 and key2 are now expired

        // Explicit prune triggers cleanup
        cache.prune();
        expect(cache.length, 1);
        expect(cache.contains('key3'), true);
      });
    });

    group('Edge Cases', () {
      test('maxSize=1 works correctly', () {
        final cache = LruCache<String>(
          maxSize: 1,
          ttl: const Duration(seconds: 60),
        );
        cache.add('key1');
        expect(cache.contains('key1'), true);
        cache.add('key2');
        expect(cache.contains('key1'), false);
        expect(cache.contains('key2'), true);
        expect(cache.length, 1);
      });

      test('zero TTL expires immediately', () async {
        final cache = LruCache<String>(maxSize: 10, ttl: Duration.zero);
        cache.add('key1');
        await Future.delayed(const Duration(milliseconds: 1));
        expect(cache.contains('key1'), false);
      });

      test('very long TTL allows long-lived entries', () {
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(hours: 24),
        );
        cache.add('key1');
        expect(cache.contains('key1'), true);
        expect(cache.length, 1);
      });
    });

    group('Lazy Expiration Behavior', () {
      test('contains checks only specific key timestamp (O(1))', () {
        var now = DateTime(2026, 5, 27, 10, 0, 0);
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        cache.add('key1');
        cache.add('key2');

        // Advance time to expire key1 and key2
        now = now.add(const Duration(seconds: 61));

        // Add key3 after time advancement (not expired)
        cache.add('key3');

        // Check key3 (not expired) - should not trigger full cleanup
        expect(cache.contains('key3'), true);
        expect(cache.length, 3); // All still in map (lazy expiration)

        // Check key1 (expired) - increments dirty counter but doesn't clean
        expect(cache.contains('key1'), false);
        expect(cache.length, 3); // Still all in map

        // Explicit prune removes expired entries
        cache.prune();
        expect(cache.length, 1); // Only key3 remains
      });

      test('lazy cleanup triggers when dirty count exceeds threshold', () {
        var now = DateTime(2026, 5, 27, 10, 0, 0);
        final cache = LruCache<String>(
          maxSize: 8, // Threshold = 8/4 = 2
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        // Add 8 entries
        for (var i = 0; i < 8; i++) {
          cache.add('key$i');
        }

        // Expire all entries
        now = now.add(const Duration(seconds: 61));

        // Check first entry (dirty count = 1, below threshold)
        expect(cache.contains('key0'), false);
        expect(cache.length, 8);

        // Check second entry (dirty count = 2, at threshold)
        // Next add() should trigger cleanup
        expect(cache.contains('key1'), false);
        expect(cache.length, 8);

        // Add new entry - should trigger lazy cleanup
        cache.add('key_new');
        expect(cache.length, 1); // All expired entries cleaned
        expect(cache.contains('key_new'), true);
      });

      test('injectable clock allows deterministic testing', () {
        var now = DateTime(2026, 5, 27, 10, 0, 0);
        final cache = LruCache<String>(
          maxSize: 10,
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        cache.add('key1');
        expect(cache.contains('key1'), true);

        // Advance time by 59 seconds (not expired)
        now = now.add(const Duration(seconds: 59));
        expect(cache.contains('key1'), true);

        // Advance time by 2 more seconds (now expired)
        now = now.add(const Duration(seconds: 2));
        expect(cache.contains('key1'), false);
      });

      test('dirty counter resets after prune', () {
        var now = DateTime(2026, 5, 27, 10, 0, 0);
        final cache = LruCache<String>(
          maxSize: 8,
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        cache.add('key1');
        cache.add('key2');

        // Expire entries
        now = now.add(const Duration(seconds: 61));

        // Check both (dirty count = 2)
        cache.contains('key1');
        cache.contains('key2');

        // Prune resets dirty counter
        cache.prune();

        // Add 8 more entries (should not trigger cleanup even though dirty was 2)
        for (var i = 0; i < 8; i++) {
          cache.add('key$i');
        }
        expect(cache.length, 8); // No unexpected cleanup
      });

      test('lazy cleanup preserves non-expired entries', () {
        var now = DateTime(2026, 5, 27, 10, 0, 0);
        final cache = LruCache<String>(
          maxSize: 8,
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        // Add 4 entries
        for (var i = 0; i < 4; i++) {
          cache.add('old$i');
        }

        // Advance time and add 4 more entries (old ones expired)
        now = now.add(const Duration(seconds: 61));
        for (var i = 0; i < 4; i++) {
          cache.add('new$i');
        }

        // Check expired entries to build up dirty count
        cache.contains('old0');
        cache.contains('old1');

        // Add one more to trigger cleanup (dirty count = 2, threshold = 2)
        cache.add('trigger');

        // Only non-expired entries remain
        expect(cache.length, 5); // 4 new + 1 trigger
        for (var i = 0; i < 4; i++) {
          expect(cache.contains('new$i'), true);
        }
        expect(cache.contains('trigger'), true);
      });
    });
  });
}
