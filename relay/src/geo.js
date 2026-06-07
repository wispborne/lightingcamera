// Bounding-box helpers. Clients subscribe with a center + radius; we forward only
// strikes inside the resulting box. Radius is clamped to the configured maximum.
//
// Note: ignores antimeridian (±180° lon) wraparound — fine for the small radii this
// relay serves (a few hundred km), not intended for boxes spanning the date line.

const KM_PER_DEG_LAT = 111.32;

/** Clamp a requested radius (km) to [1, maxRadiusKm]. */
export function clampRadiusKm(radiusKm, maxRadiusKm) {
  if (!Number.isFinite(radiusKm) || radiusKm <= 0) return maxRadiusKm;
  return Math.min(radiusKm, maxRadiusKm);
}

/** Build a lat/lon box around a center point for a given radius in km. */
export function boxFromCenter(lat, lon, radiusKm) {
  const dLat = radiusKm / KM_PER_DEG_LAT;
  const cos = Math.cos((lat * Math.PI) / 180);
  const dLon = radiusKm / (KM_PER_DEG_LAT * Math.max(cos, 1e-6));
  return {
    minLat: lat - dLat,
    maxLat: lat + dLat,
    minLon: lon - dLon,
    maxLon: lon + dLon,
  };
}

/** True if a {lat, lon} strike falls inside the box. */
export function inBox(strike, box) {
  return (
    strike.lat >= box.minLat &&
    strike.lat <= box.maxLat &&
    strike.lon >= box.minLon &&
    strike.lon <= box.maxLon
  );
}
