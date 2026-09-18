import type { Earthquake } from '$lib/earthquakes/types';
import type { Hazard } from '$lib/hazards/types';
import type { Alert } from '$lib/alerts/types';
import type {
	AlertTimelineItem,
	EarthquakeTimelineItem,
	HazardTimelineItem,
	TimelineFilters,
	TimelineItem,
	TimelineKind,
	TimelineSeverity
} from './types';

const SEVERITY_RANK: Record<TimelineSeverity, number> = {
	unknown: 0,
	minor: 1,
	moderate: 2,
	severe: 3,
	extreme: 4
};

export function severityRank(severity: TimelineSeverity): number {
	return SEVERITY_RANK[severity];
}

export function severityForEarthquake(magnitude: number | null): TimelineSeverity {
	if (magnitude === null) return 'unknown';
	if (magnitude < 4.5) return 'minor';
	if (magnitude < 6) return 'moderate';
	if (magnitude < 7) return 'severe';
	return 'extreme';
}

export function severityForHazard(capSeverity: string): TimelineSeverity {
	if (capSeverity === 'minor' || capSeverity === 'severe' || capSeverity === 'extreme') {
		return capSeverity;
	}
	return 'unknown';
}

const ALERT_SEVERITY: Record<string, TimelineSeverity> = {
	extreme: 'extreme',
	severe: 'severe',
	moderate: 'moderate',
	minor: 'minor'
};

export function severityForAlert(noaaSeverity: string): TimelineSeverity {
	return ALERT_SEVERITY[noaaSeverity.toLowerCase()] ?? 'unknown';
}

export function itemFromRecord(kind: 'earthquake', record: Earthquake): EarthquakeTimelineItem;
export function itemFromRecord(kind: 'hazard', record: Hazard): HazardTimelineItem;
export function itemFromRecord(kind: 'alert', record: Alert): AlertTimelineItem;
export function itemFromRecord(
	kind: TimelineKind,
	record: Earthquake | Hazard | Alert
): TimelineItem {
	if (kind === 'earthquake') {
		const earthquake = record as Earthquake;
		return {
			kind: 'earthquake',
			key: `earthquake:${earthquake.id}`,
			seen_at: earthquake.first_seen_at,
			seen_at_ms: new Date(earthquake.first_seen_at).getTime(),
			severity: severityForEarthquake(earthquake.magnitude),
			ended: false,
			earthquake
		};
	}
	if (kind === 'hazard') {
		const hazard = record as Hazard;
		return {
			kind: 'hazard',
			key: `hazard:${hazard.id}`,
			seen_at: hazard.first_seen_at,
			seen_at_ms: new Date(hazard.first_seen_at).getTime(),
			severity: severityForHazard(hazard.cap_severity),
			ended: !hazard.is_current,
			hazard
		};
	}
	const alert = record as Alert;
	return {
		kind: 'alert',
		key: `alert:${alert.id}`,
		seen_at: alert.first_seen_at,
		seen_at_ms: new Date(alert.first_seen_at).getTime(),
		severity: severityForAlert(alert.severity),
		ended: alert.ended_at !== null,
		alert
	};
}

/** Kinds/minmag/min_severity plus the two hard exclusions (GDACS earthquakes, deleted events). */
export function passesFilters(item: TimelineItem, filters: TimelineFilters): boolean {
	if (!filters.kinds.has(item.kind)) return false;
	if (item.kind === 'earthquake') {
		if (item.earthquake.status === 'deleted') return false;
		if (
			filters.minMagnitude !== 'all' &&
			(item.earthquake.magnitude === null || item.earthquake.magnitude < filters.minMagnitude)
		) {
			return false;
		}
	}
	if (item.kind === 'hazard' && item.hazard.hazard_type === 'earthquake') return false;
	if (
		filters.minSeverity !== 'all' &&
		severityRank(item.severity) < severityRank(filters.minSeverity)
	) {
		return false;
	}
	return true;
}

function compareDesc(a: string, b: string): number {
	if (a === b) return 0;
	return a > b ? -1 : 1;
}

/** `(seen_at_ms DESC, kind DESC, key DESC)`, matching the backend's tie-break order. */
export function compareItems(a: TimelineItem, b: TimelineItem): number {
	if (a.seen_at_ms !== b.seen_at_ms) return b.seen_at_ms - a.seen_at_ms;
	const kindOrder = compareDesc(a.kind, b.kind);
	if (kindOrder !== 0) return kindOrder;
	return compareDesc(a.key, b.key);
}
