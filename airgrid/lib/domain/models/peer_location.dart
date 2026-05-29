import 'dart:math' as math;

class PeerLocation {
  final String nodeId;
  final String displayName;
  final double latitude;
  final double longitude;
  final double? accuracyMeters;
  final double? headingDegrees;
  final DateTime updatedAt;

  const PeerLocation({
    required this.nodeId,
    required this.displayName,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
    this.accuracyMeters,
    this.headingDegrees,
  });

  factory PeerLocation.fromJson(Map<String, dynamic> json) {
    return PeerLocation(
      nodeId: json['nodeId'] as String,
      displayName: json['displayName'] as String? ?? 'Unknown',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      headingDegrees: (json['headingDegrees'] as num?)?.toDouble(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
    );
  }

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'displayName': displayName,
    'latitude': latitude,
    'longitude': longitude,
    if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
    if (headingDegrees != null) 'headingDegrees': headingDegrees,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  double distanceMetersTo(PeerLocation other) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = _toRadians(latitude);
    final lat2 = _toRadians(other.latitude);
    final deltaLat = _toRadians(other.latitude - latitude);
    final deltaLon = _toRadians(other.longitude - longitude);

    final a =
        math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  double bearingDegreesTo(PeerLocation other) {
    final lat1 = _toRadians(latitude);
    final lat2 = _toRadians(other.latitude);
    final deltaLon = _toRadians(other.longitude - longitude);
    final y = math.sin(deltaLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
    return (_toDegrees(math.atan2(y, x)) + 360) % 360;
  }

  static String cardinalDirection(double bearingDegrees) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final index = ((bearingDegrees + 22.5) ~/ 45) % directions.length;
    return directions[index];
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  static double _toDegrees(double radians) => radians * 180 / math.pi;
}
