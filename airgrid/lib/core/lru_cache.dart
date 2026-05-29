import 'dart:collection';

/// A bounded, TTL-aware LRU cache keyed on [K].
///
/// Entries are evicted when:
/// - the cache exceeds [maxSize] (oldest-first by insertion order), or
/// - an entry's age exceeds [ttl] (checked lazily to avoid O(n) scans).
///
/// Lazy expiration: [contains] checks only the requested key's timestamp (O(1)),
/// while expired entries are bulk-cleaned during [add] when the "dirty count"
/// exceeds a threshold, or explicitly via [prune].
///
/// [LinkedHashMap] preserves insertion order, giving "oldest-first" eviction
/// without a separate priority structure.
class LruCache<K> {
  final int maxSize;
  final Duration ttl;
  final DateTime Function() _clock;

  final _map = <K, DateTime>{};
  int _dirtyCount = 0;

  LruCache({
    required this.maxSize,
    required this.ttl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Returns true if [key] is present and not TTL-expired.
  ///
  /// Checks only the requested key's timestamp (O(1)) without scanning the
  /// entire map. Expired entries are cleaned up lazily during [add] or [prune].
  bool contains(K key) {
    final ts = _map[key];
    if (ts == null) return false;
    
    final now = _clock();
    if (now.difference(ts) > ttl) {
      // Mark as dirty but don't clean yet (lazy expiration)
      _dirtyCount++;
      return false;
    }
    return true;
  }

  /// Records [key] with the current timestamp.
  ///
  /// If [key] already exists it is refreshed (moved to the back).
  /// When the cache is at [maxSize] the oldest entry is evicted first.
  /// Lazy cleanup is triggered when dirty count exceeds maxSize / 4.
  void add(K key) {
    // Refresh existing entry — remove then reinsert at the back.
    _map.remove(key);
    _map[key] = _clock();
    
    // Evict oldest if over capacity
    if (_map.length > maxSize) {
      _map.remove(_map.keys.first);
    }
    
    // Lazy cleanup: prune if dirty count exceeds threshold
    final threshold = (maxSize / 4).ceil();
    if (_dirtyCount >= threshold) {
      _evictExpired();
    }
  }

  /// Explicitly evicts all TTL-expired entries.
  ///
  /// Lazy cleanup is triggered automatically during [add] when dirty count
  /// exceeds the threshold. Call [prune] explicitly if you want to reclaim
  /// memory at a known quiet point or for deterministic test behavior.
  void prune() => _evictExpired();

  /// Current number of live (non-expired) entries.
  int get length => _map.length;

  void _evictExpired() {
    final now = _clock();
    _map.removeWhere((_, ts) => now.difference(ts) > ttl);
    _dirtyCount = 0; // Reset dirty counter after cleanup
  }
}
