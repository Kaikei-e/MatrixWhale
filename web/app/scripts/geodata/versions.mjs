// See build.mjs header for the NWS version-bump workflow.

export const SOURCES = {
	forecastZones: {
		url: 'https://www.weather.gov/source/gis/Shapefiles/WSOM/z_16ap26.zip',
		version: '2026-04-16',
		sha256: '010dc5eab64b6e326c969e252bd016f56a037b0444df8303658707bca4cc7fd8',
		outputFile: 'nws-forecast-zones-2026-04-16.json'
	},
	counties: {
		url: 'https://www.weather.gov/source/gis/Shapefiles/County/c_16ap26.zip',
		version: '2026-04-16',
		sha256: '503f9d697a97bdbfd8a7cfe6b3b666801f43392fa220294987a68cac0bd3f03b',
		outputFile: 'nws-counties-2026-04-16.json'
	},
	marineCoastal: {
		url: 'https://www.weather.gov/source/gis/Shapefiles/WSOM/mz16ap26.zip',
		version: '2026-04-16',
		sha256: '97f6317f4ebef4994940b3851e9f889a71b06914eb41d77dd6edbebd46b5184d',
		outputFile: 'nws-marine-coastal-zones-2026-04-16.json'
	},
	marineOffshore: {
		url: 'https://www.weather.gov/source/gis/Shapefiles/WSOM/oz16ap26.zip',
		version: '2026-04-16',
		sha256: '07d1514e9bf4b434b2d1f14f803751cd2a3a1dc8119507ec88edcb5c99b4932f',
		outputFile: 'nws-marine-offshore-zones-2026-04-16.json'
	},
	marineHighSeas: {
		url: 'https://www.weather.gov/source/gis/Shapefiles/WSOM/hz17fe26.zip',
		version: '2026-02-17',
		sha256: '048967e532c300f5047cb25ff1756ded416d68aa5465a54e3568a7c6183d47f0',
		centroidsOnly: true
	}
};

export const NATURAL_EARTH_VERSION = '5.1.1';

// world-atlas ships Natural Earth "land" without lake holes, so the Great
// Lakes would render as land; these lake polygons are erased from it.
export const LAKE_SOURCES = {
	lakes50m: {
		url: 'https://naciscdn.org/naturalearth/50m/physical/ne_50m_lakes.zip',
		version: '5.0.0',
		sha256: 'f28d42c286d96b57a17aac2cbeb432f8c65532c20063495711fbc64e24666df3'
	},
	lakes110m: {
		url: 'https://naciscdn.org/naturalearth/110m/physical/ne_110m_lakes.zip',
		version: '5.0.0',
		sha256: 'f2eed3c738a93010770acb0ba44273ea6a83b053641588bc902d9d6fd1cdafcb'
	}
};
export const CENTROIDS_FILE = 'zone-centroids-2026-04-16.json';
export const MANIFEST_FILE = 'geodata-manifest.json';
