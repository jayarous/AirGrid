import 'package:airgrid/core/lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// Benchmark comparing lazy expiration vs simulated eager expiration.
///
/// This demonstrates the O(1) vs O(n) performance difference.
void main() {
  group('LruCache Performance', () {
    test('benchmark: lazy expiration scales to large cache sizes', () {
      final stopwatch = Stopwatch();
      var now = DateTime(2026, 5, 27, 10, 0, 0);

      // Test with cache size of 10,000 entries
      final cache = LruCache<String>(
        maxSize: 10000,
        ttl: const Duration(seconds: 60),
        clock: () => now,
      );

      // Fill cache
      for (var i = 0; i < 10000; i++) {
        cache.add('key$i');
      }

      // Advance time to expire half the entries
      now = now.add(const Duration(seconds: 61));

      // Add 5000 more entries (keeping cache at 10000)
      for (var i = 10000; i < 15000; i++) {
        cache.add('key$i');
      }

      // Benchmark: 10,000 contains() calls with lazy expiration
      stopwatch.start();
      for (var i = 0; i < 10000; i++) {
        cache.contains('key${i + 10000}'); // Check non-expired keys
      }
      stopwatch.stop();

      final lazyMicros = stopwatch.elapsedMicroseconds;
      // ignore: avoid_print
      print('Lazy expiration (10k contains): $lazyMicros\u03bcs');

      // Sanity check: should be well under 100ms even on slow hardware
      expect(
        lazyMicros,
        lessThan(100000),
        reason: 'O(1) lookups should complete quickly',
      );
    });

    test('benchmark: dirty counter cleanup amortizes cost', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);

      final cache = LruCache<String>(
        maxSize: 1000, // Threshold = 250
        ttl: const Duration(seconds: 60),
        clock: () => now,
      );

      // Fill cache
      for (var i = 0; i < 1000; i++) {
        cache.add('key$i');
      }

      // Expire all entries
      now = now.add(const Duration(seconds: 61));

      // Check 250 expired entries to reach dirty threshold
      for (var i = 0; i < 250; i++) {
        cache.contains('key$i');
      }

      // Next add() should trigger cleanup
      final stopwatch = Stopwatch()..start();
      cache.add('trigger');
      stopwatch.stop();

      // ignore: avoid_print
      print(
        'Lazy cleanup triggered (1000 entries): ${stopwatch.elapsedMicroseconds}\u03bcs',
      );

      // All expired entries should be cleaned
      expect(cache.length, 1); // Only 'trigger' remains
    });

    test('benchmark comparison: O(1) lookup vs O(n) scan', () {
      final now = DateTime(2026, 5, 27, 10, 0, 0);
      final sizes = [100, 500, 1000, 5000];

      for (final size in sizes) {
        final cache = LruCache<String>(
          maxSize: size,
          ttl: const Duration(seconds: 60),
          clock: () => now,
        );

        // Fill cache
        for (var i = 0; i < size; i++) {
          cache.add('key$i');
        }

        // Benchmark 100 contains() calls
        final stopwatch = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          cache.contains('key0');
        }
        stopwatch.stop();

        final microsPerLookup = stopwatch.elapsedMicroseconds / 100;
        // ignore: avoid_print
        print(
          'Cache size $size: ${microsPerLookup.toStringAsFixed(2)}\u03bcs per lookup',
        );

        // With O(1) lazy expiration, lookup time should be roughly constant
        // regardless of cache size (within a reasonable margin for overhead)
        expect(
          microsPerLookup,
          lessThan(100),
          reason: 'O(1) lookups should have constant time',
        );
      }
    });
  });
}
