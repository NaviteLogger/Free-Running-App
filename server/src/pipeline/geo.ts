const EARTH_RADIUS_M = 6371008.8;

const rad = (deg: number): number => (deg * Math.PI) / 180;

/** Great-circle distance in metres. */
export function haversineM(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const phi1 = rad(lat1);
  const phi2 = rad(lat2);
  const dPhi = rad(lat2 - lat1);
  const dLambda = rad(lon2 - lon1);

  const a =
    Math.sin(dPhi / 2) * Math.sin(dPhi / 2) +
    Math.cos(phi1) * Math.cos(phi2) * Math.sin(dLambda / 2) * Math.sin(dLambda / 2);

  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Encoded polyline, the Google format, precision 5.
 *
 * Used so the activity list can draw a route thumbnail from one text column
 * without reading the raw points. That is what keeps the list query inside its
 * budget.
 *
 * The encoder rounds each coordinate to five decimal places, so the same input
 * always produces the same string. That matters: reprocessing an activity twice
 * has to give a byte-identical result.
 */
export function encodePolyline(points: readonly { lat: number; lon: number }[]): string {
  let lastLat = 0;
  let lastLon = 0;
  let out = '';

  for (const point of points) {
    const lat = Math.round(point.lat * 1e5);
    const lon = Math.round(point.lon * 1e5);
    out += encodeSigned(lat - lastLat) + encodeSigned(lon - lastLon);
    lastLat = lat;
    lastLon = lon;
  }
  return out;
}

function encodeSigned(value: number): string {
  let v = value < 0 ? ~(value << 1) : value << 1;
  let out = '';
  while (v >= 0x20) {
    out += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  out += String.fromCharCode(v + 63);
  return out;
}

export function decodePolyline(encoded: string): { lat: number; lon: number }[] {
  const points: { lat: number; lon: number }[] = [];
  let index = 0;
  let lat = 0;
  let lon = 0;

  while (index < encoded.length) {
    lat += decodeSigned();
    lon += decodeSigned();
    points.push({ lat: lat / 1e5, lon: lon / 1e5 });
  }
  return points;

  function decodeSigned(): number {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      if (index >= encoded.length) {
        throw new Error('polyline ended mid-value');
      }
      // charCodeAt returns NaN past the end, which `??` does not catch, so the
      // bounds check above is the real guard. Anything below 63 is not part of
      // the alphabet this encoding uses.
      const code = encoded.charCodeAt(index++);
      if (code < 63) throw new Error(`polyline has an invalid character at ${index - 1}`);
      byte = code - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  }
}
