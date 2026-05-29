import 'package:shared_preferences/shared_preferences.dart';

const nearbyUseDeviceCompassPrefKey = 'nearby_use_device_compass';
const nearbySmoothingAlphaPrefKey = 'nearby_smoothing_alpha';
const nearbyDefaultSmoothingAlpha = 0.12;
const nearbyMinSmoothingAlpha = 0.04;
const nearbyMaxSmoothingAlpha = 0.30;

double normalizeNearbySmoothingAlpha(double value) {
  if (value.isNaN) return nearbyDefaultSmoothingAlpha;
  return value.clamp(nearbyMinSmoothingAlpha, nearbyMaxSmoothingAlpha);
}

double readNearbySmoothingAlpha(SharedPreferences prefs) {
  return normalizeNearbySmoothingAlpha(
    prefs.getDouble(nearbySmoothingAlphaPrefKey) ?? nearbyDefaultSmoothingAlpha,
  );
}
