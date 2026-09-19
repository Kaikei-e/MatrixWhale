export const NWS_PRIORITY: Record<string, number> = {
	'Tsunami Warning': 1,
	'Tornado Warning': 2,
	'Extreme Wind Warning': 3,
	'Severe Thunderstorm Warning': 4,
	'Flash Flood Warning': 5,
	'Flash Flood Statement': 6,
	'Severe Weather Statement': 7,
	'Shelter In Place Warning': 8,
	'Evacuation Immediate': 9,
	'Civil Danger Warning': 10,
	'Nuclear Power Plant Warning': 11,
	'Radiological Hazard Warning': 12,
	'Hazardous Materials Warning': 13,
	'Fire Warning': 14,
	'Civil Emergency Message': 15,
	'Law Enforcement Warning': 16,
	'Storm Surge Warning': 17,
	'Hurricane Force Wind Warning': 18,
	'Hurricane Warning': 19,
	'Typhoon Warning': 20,
	'Special Marine Warning': 21,
	'Blizzard Warning': 22,
	'Snow Squall Warning': 23,
	'Ice Storm Warning': 24,
	'Heavy Freezing Spray Warning': 25,
	'Winter Storm Warning': 26,
	'Lake Effect Snow Warning': 27,
	'Dust Storm Warning': 28,
	'Blowing Dust Warning': 29,
	'High Wind Warning': 30,
	'Tropical Storm Warning': 31,
	'Storm Warning': 32,
	'Tsunami Advisory': 33,
	'Tsunami Watch': 34,
	'Avalanche Warning': 35,
	'Earthquake Warning': 36,
	'Volcano Warning': 37,
	'Ashfall Warning': 38,
	'Flood Warning': 39,
	'Coastal Flood Warning': 40,
	'Lakeshore Flood Warning': 41,
	'Ashfall Advisory': 42,
	'High Surf Warning': 43,
	'Extreme Heat Warning': 44,
	'Tornado Watch': 45,
	'Severe Thunderstorm Watch': 46,
	'Flash Flood Watch': 47,
	'Gale Warning': 48,
	'Flood Statement': 49,
	'Extreme Cold Warning': 50,
	'Freeze Warning': 51,
	'Red Flag Warning': 52,
	'Storm Surge Watch': 53,
	'Hurricane Watch': 54,
	'Hurricane Force Wind Watch': 55,
	'Typhoon Watch': 56,
	'Tropical Storm Watch': 57,
	'Storm Watch': 58,
	'Tropical Cyclone Local Statement': 59,
	'Winter Weather Advisory': 60,
	'Avalanche Advisory': 61,
	'Cold Weather Advisory': 62,
	'Heat Advisory': 63,
	'Flood Advisory': 64,
	'Coastal Flood Advisory': 65,
	'Lakeshore Flood Advisory': 66,
	'High Surf Advisory': 67,
	'Dense Fog Advisory': 68,
	'Dense Smoke Advisory': 69,
	'Small Craft Advisory': 70,
	'Brisk Wind Advisory': 71,
	'Hazardous Seas Warning': 72,
	'Dust Advisory': 73,
	'Blowing Dust Advisory': 74,
	'Lake Wind Advisory': 75,
	'Wind Advisory': 76,
	'Frost Advisory': 77,
	'Freezing Fog Advisory': 78,
	'Freezing Spray Advisory': 79,
	'Low Water Advisory': 80,
	'Local Area Emergency': 81,
	'Winter Storm Watch': 82,
	'Rip Current Statement': 83,
	'Beach Hazards Statement': 84,
	'Gale Watch': 85,
	'Avalanche Watch': 86,
	'Hazardous Seas Watch': 87,
	'Heavy Freezing Spray Watch': 88,
	'Flood Watch': 89,
	'Coastal Flood Watch': 90,
	'Lakeshore Flood Watch': 91,
	'High Wind Watch': 92,
	'Extreme Heat Watch': 93,
	'Extreme Cold Watch': 94,
	'Freeze Watch': 95,
	'Fire Weather Watch': 96,
	'Extreme Fire Danger': 97,
	'911 Telephone Outage': 98,
	'Coastal Flood Statement': 99,
	'Lakeshore Flood Statement': 100,
	'Special Weather Statement': 101,
	'Marine Weather Statement': 102,
	'Air Quality Alert': 103,
	'Air Stagnation Advisory': 104,
	'Hazardous Weather Outlook': 105,
	'Hydrologic Outlook': 106,
	'Short Term Forecast': 107,
	'Administrative Message': 108,
	Test: 109,
	'Child Abduction Emergency': 110,
	'Blue Alert': 111
};

export const UNKNOWN_PRIORITY = 999;

export const SEVERITY_RANK: Record<string, number> = {
	extreme: 4,
	severe: 3,
	moderate: 2,
	minor: 1,
	unknown: 0
};

export function severityRank(severity: string | null | undefined): number {
	if (!severity) return 0;
	return SEVERITY_RANK[severity.toLowerCase()] ?? 0;
}

export const URGENCY_RANK: Record<string, number> = {
	immediate: 4,
	expected: 3,
	future: 2,
	past: 1,
	unknown: 0
};

export function urgencyRank(urgency: string | null | undefined): number {
	if (!urgency) return 0;
	return URGENCY_RANK[urgency.toLowerCase()] ?? 0;
}

export interface SortableAlert {
	source?: string;
	event: string;
	severity?: string;
	urgency?: string;
	sent: string | null;
	first_seen_at?: string;
	id?: string;
}

export function compareAlerts<T extends SortableAlert>(a: T, b: T): number {
	const sevDiff = severityRank(b.severity) - severityRank(a.severity);
	if (sevDiff !== 0) return sevDiff;

	const priorityA =
		a.source === 'noaa' ? (NWS_PRIORITY[a.event] ?? UNKNOWN_PRIORITY) : UNKNOWN_PRIORITY;
	const priorityB =
		b.source === 'noaa' ? (NWS_PRIORITY[b.event] ?? UNKNOWN_PRIORITY) : UNKNOWN_PRIORITY;
	if (priorityA !== priorityB) return priorityA - priorityB;

	const urgDiff = urgencyRank(b.urgency) - urgencyRank(a.urgency);
	if (urgDiff !== 0) return urgDiff;

	const sentDiff = (b.sent ?? '').localeCompare(a.sent ?? '');
	if (sentDiff !== 0) return sentDiff;

	return (a.id ?? '').localeCompare(b.id ?? '');
}

export function sortByNwsPriority<T extends SortableAlert>(alerts: T[]): T[] {
	return [...alerts].sort(compareAlerts);
}
