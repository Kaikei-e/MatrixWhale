/**
 * Un-wraps one ring's longitudes into a continuous sequence by tracking a
 * running +-360 offset across raw antimeridian jumps (|dlon| > 180). A ring
 * whose net offset winds up near +-360 (its last vertex, a repeat of the
 * first, no longer lines up with it after unwrapping) is circling a pole;
 * it is closed through the pole instead of left as a 360deg-wide gap.
 */
function unwrapRing(ring) {
	const n = ring.length;
	const unwrapped = new Array(n);
	unwrapped[0] = ring[0].slice();
	let offset = 0;
	for (let i = 1; i < n; i++) {
		const diff = ring[i][0] - ring[i - 1][0];
		if (diff > 180) offset -= 360;
		else if (diff < -180) offset += 360;
		unwrapped[i] = [ring[i][0] + offset, ring[i][1]];
	}

	const firstLon = unwrapped[0][0];
	const lastLon = unwrapped[n - 1][0];
	if (Math.abs(lastLon - firstLon) < 180) return unwrapped;

	const dropped = unwrapped.slice(0, n - 1);
	const meanLat = dropped.reduce((sum, pt) => sum + pt[1], 0) / dropped.length;
	const poleLat = meanLat < 0 ? -90 : 90;
	const [firstLonPt, firstLat] = dropped[0];
	const closingLastLon = dropped[dropped.length - 1][0];

	// The pole-cap edge itself still spans ~360deg of longitude; a single
	// segment for it would trip the same "world-spanning edge" check this fix
	// exists to satisfy (and mapshaper's -clean is free to leave a long
	// straight segment alone). Sample it in <=30deg steps instead — still a
	// single straight edge in lon/lat terms, but no consecutive pair exceeds
	// the antimeridian-jump threshold, and at exactly the pole it renders as
	// nothing (a point) regardless.
	const capStepDeg = 30;
	const capDelta = firstLonPt - closingLastLon;
	const capSteps = Math.ceil(Math.abs(capDelta) / capStepDeg);
	const cap = [];
	for (let k = 0; k <= capSteps; k++) {
		cap.push([closingLastLon + (capDelta * k) / capSteps, poleLat]);
	}
	return [...dropped, ...cap, [firstLonPt, firstLat]];
}

/**
 * Rebuilds a Polygon/MultiPolygon so every ring's longitudes are continuous
 * across the antimeridian instead of jumping from +180 to -180 within one
 * ring. geojson-vt (MapLibre's tiler) treats a raw 360deg jump as an edge
 * spanning the whole world; unwrapping avoids that, at the cost of
 * coordinates that can fall outside [-180, 180] (fine with
 * renderWorldCopies, which this app already relies on for zone rendering).
 * Returns a new geometry; does not mutate the input.
 */
export function unwrapAntimeridian(geometry) {
	if (geometry.type === 'Polygon') {
		return { type: 'Polygon', coordinates: geometry.coordinates.map(unwrapRing) };
	}
	if (geometry.type === 'MultiPolygon') {
		return {
			type: 'MultiPolygon',
			coordinates: geometry.coordinates.map((rings) => rings.map(unwrapRing))
		};
	}
	return geometry;
}

/**
 * Longitude bbox span in degrees for a Polygon/MultiPolygon geometry.
 * Naive min/max — deliberately does not account for wraparound, since that
 * is exactly what `fixAntimeridian` below corrects for.
 */
export function lonBboxSpan(geometry) {
	let minLon = Infinity;
	let maxLon = -Infinity;
	const depth = geometry.type === 'Polygon' ? 2 : geometry.type === 'MultiPolygon' ? 3 : 0;
	(function walk(coords, d) {
		if (d === 0) {
			minLon = Math.min(minLon, coords[0]);
			maxLon = Math.max(maxLon, coords[0]);
			return;
		}
		for (const c of coords) walk(c, d - 1);
	})(geometry.coordinates, depth);
	return maxLon - minLon;
}

function polygonParts(geometry) {
	return geometry.type === 'Polygon' ? [geometry.coordinates] : geometry.coordinates;
}

function partCenterLon(ringSet) {
	const ring = ringSet[0];
	let sum = 0;
	for (const pt of ring) sum += pt[0];
	return sum / ring.length;
}

function cloneParts(parts) {
	return parts.map((ringSet) => ringSet.map((ring) => ring.map((pt) => pt.slice())));
}

function shiftParts(parts, delta, predicate) {
	for (const ringSet of parts) {
		if (predicate(partCenterLon(ringSet))) {
			for (const ring of ringSet) for (const pt of ring) pt[0] += delta;
		}
	}
}

function partsSpan(parts) {
	let minLon = Infinity;
	let maxLon = -Infinity;
	for (const ringSet of parts)
		for (const ring of ringSet)
			for (const pt of ring) {
				minLon = Math.min(minLon, pt[0]);
				maxLon = Math.max(maxLon, pt[0]);
			}
	return maxLon - minLon;
}

/**
 * Fixes features whose naive longitude bbox span exceeds 180°.
 *
 * For these NWS zone/county sources, no individual ring actually crosses the
 * antimeridian (verified by inspection) — the wide span is an artifact of a
 * single ugc's polygon parts (e.g. separate Aleutian islands) being split
 * naturally across +179..180 and -180..-179. The fix re-centers whichever
 * side is the minority by a whole +-360 shift so the whole feature becomes
 * longitude-contiguous, trying both directions and keeping the smaller span.
 *
 * Mutates and returns the feature. Throws if the span cannot be brought
 * under 180° (would indicate an actual mid-ring crossing, which this
 * heuristic does not handle).
 */
export function fixAntimeridian(feature) {
	const span = lonBboxSpan(feature.geometry);
	if (span <= 180) return { feature, fixed: false, span };

	const geom = feature.geometry;
	const parts = polygonParts(geom);

	const eastward = cloneParts(parts);
	shiftParts(eastward, 360, (c) => c < 0);
	const eastwardSpan = partsSpan(eastward);

	const westward = cloneParts(parts);
	shiftParts(westward, -360, (c) => c > 0);
	const westwardSpan = partsSpan(westward);

	const best = eastwardSpan <= westwardSpan ? eastward : westward;
	const bestSpan = Math.min(eastwardSpan, westwardSpan);

	if (bestSpan > 180) {
		throw new Error(
			`antimeridian fix failed for ugc=${feature.properties?.ugc ?? '?'}: span still ${bestSpan.toFixed(2)}° after shift`
		);
	}

	geom.coordinates = geom.type === 'Polygon' ? best[0] : best;
	return { feature, fixed: true, span: bestSpan };
}
