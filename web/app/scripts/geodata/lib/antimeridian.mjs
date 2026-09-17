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
