import { SEVERITIES, type Alert, type Severity } from './types';

export function extractGeocodes(alert: Alert, name: string): string[] {
	if (!alert.geocodes || !Array.isArray(alert.geocodes)) return [];
	const searchName = name.toUpperCase();
	const results: string[] = [];
	for (const geocode of alert.geocodes) {
		if (geocode && typeof geocode.name === 'string' && geocode.name.toUpperCase() === searchName) {
			if (typeof geocode.value === 'string') {
				const parts = geocode.value.trim().split(/[\s,]+/);
				for (const part of parts) {
					if (part) results.push(part);
				}
			}
		}
	}
	return results;
}

export function extractUgc(alert: Alert): string[] {
	return extractGeocodes(alert, 'UGC');
}

export function extractSame(alert: Alert): string[] {
	return extractGeocodes(alert, 'SAME');
}

export function computeZoneSeverity(alerts: Alert[]): Map<string, Severity> {
	const result = new Map<string, Severity>();
	for (const alert of alerts) {
		for (const ugc of extractUgc(alert)) {
			const current = result.get(ugc);
			if (!current || SEVERITIES.indexOf(alert.severity) < SEVERITIES.indexOf(current)) {
				result.set(ugc, alert.severity);
			}
		}
	}
	return result;
}
