import type { Alert } from './types';

export interface SourceAttribution {
	name: string;
	count: number;
}

export interface AttributionSummary {
	visible: SourceAttribution[];
	hiddenCount: number;
	totalUnique: number;
}

export function summarizeAlertSources(alerts: Alert[], limit: number = 3): AttributionSummary {
	const counts = new Map<string, number>();
	for (const alert of alerts) {
		const name = alert.source_name || alert.source;
		if (name) {
			counts.set(name, (counts.get(name) ?? 0) + 1);
		}
	}

	const sorted = [...counts.entries()]
		.map(([name, count]) => ({ name, count }))
		.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));

	return {
		visible: sorted.slice(0, limit),
		hiddenCount: Math.max(0, sorted.length - limit),
		totalUnique: sorted.length
	};
}
