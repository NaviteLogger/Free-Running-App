import 'dart:math' as math;

import '../data/models.dart';

const double _earthRadiusMetres = 6371008.8;

/// Great-circle distance in metres.
///
/// Haversine rather than a projected approximation: it is accurate to well
/// under a metre at the distances between consecutive GPS fixes, and it does
/// not fall apart near the poles or the antimeridian. The cost is irrelevant at
/// one call per second.
double haversineMetres(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = _rad(lat1);
  final phi2 = _rad(lat2);
  final dPhi = _rad(lat2 - lat1);
  final dLambda = _rad(lon2 - lon1);

  final a =
      math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);

  return _earthRadiusMetres * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _rad(double degrees) => degrees * math.pi / 180.0;

/// Running distance total for the on-screen readout.
///
/// This is deliberately *not* the number the server will publish. The server
/// recomputes everything from the raw points with a pipeline that can be
/// retuned and re-run over the whole archive; this one exists so the screen has
/// something honest to show while you are running, and the two are expected to
/// disagree slightly. Making them agree would mean shipping the phone's
/// arithmetic to the server, which is the thing the architecture is avoiding.
class DistanceAccumulator {
  DistanceAccumulator({
    this.accuracyGateMetres = 30.0,
    this.minStepMetres = 2.0,
  });

  /// Fixes worse than this are ignored for display. A 60 m fix in a street
  /// canyon can teleport you across a block and add phantom distance.
  final double accuracyGateMetres;

  /// Steps below this are treated as GPS jitter rather than movement. Standing
  /// still with a 5 m accuracy fix still wanders a metre or two per sample, and
  /// at 1 Hz that silently accumulates into kilometres over an hour.
  final double minStepMetres;

  double _metres = 0;
  double? _lat;
  double? _lon;

  double get metres => _metres;

  /// Feed every stored fix. Returns the new total.
  double add(Fix fix) {
    final accuracy = fix.accuracy;
    if (accuracy != null && accuracy > accuracyGateMetres) return _metres;

    final lastLat = _lat;
    final lastLon = _lon;
    if (lastLat != null && lastLon != null) {
      final step = haversineMetres(lastLat, lastLon, fix.lat, fix.lon);
      if (step < minStepMetres) return _metres;
      _metres += step;
    }

    _lat = fix.lat;
    _lon = fix.lon;
    return _metres;
  }

  /// Rebuild from stored rows, for resuming an interrupted session.
  void replay(Iterable<Fix> fixes) {
    for (final fix in fixes) {
      add(fix);
    }
  }

  /// Called after a pause so the gap is not counted as a straight-line sprint
  /// from where you stopped to where you started again.
  void breakSegment() {
    _lat = null;
    _lon = null;
  }
}
