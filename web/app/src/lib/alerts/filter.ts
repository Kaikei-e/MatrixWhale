import type { Alert, Severity } from './types';

export function filterAlerts(alerts: Alert[], severities: Set<Severity>, country: string): Alert[] {
	const matchCountry = country && country !== 'all';
	const upperCountry = matchCountry ? country.toUpperCase() : '';

	return alerts.filter((alert) => {
		if (!severities.has(alert.severity)) return false;

		if (matchCountry) {
			if (!alert.countries || alert.countries.length === 0) return false;
			const hasCountry = alert.countries.some((c) => c.toUpperCase() === upperCountry);
			if (!hasCountry) return false;
		}

		return true;
	});
}
