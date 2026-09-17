function round4(n) {
	return Math.round(n * 10000) / 10000;
}

/**
 * Merges centroid entries from all NWS sources into a single sorted dict.
 * @param {Array<{ugc: string, lon: number, lat: number}>} entries
 */
export function buildCentroidDict(entries) {
	const dict = {};
	for (const { ugc, lon, lat } of entries) {
		if (Object.prototype.hasOwnProperty.call(dict, ugc)) {
			throw new Error(`duplicate ugc across centroid sources: ${ugc}`);
		}
		dict[ugc] = [round4(lon), round4(lat)];
	}

	const sorted = {};
	for (const key of Object.keys(dict).sort()) sorted[key] = dict[key];
	return sorted;
}
