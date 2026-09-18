import type { Earthquake } from '$lib/earthquakes/types';
import type { Hazard } from '$lib/hazards/types';
import type { Alert } from '$lib/alerts/types';

export type TimelineKind = 'earthquake' | 'hazard' | 'alert';

export type TimelineSeverity = 'unknown' | 'minor' | 'moderate' | 'severe' | 'extreme';

interface TimelineItemBase {
	key: string;
	seen_at: string;
	seen_at_ms: number;
	severity: TimelineSeverity;
	ended: boolean;
}

export interface EarthquakeTimelineItem extends TimelineItemBase {
	kind: 'earthquake';
	earthquake: Earthquake;
}

export interface HazardTimelineItem extends TimelineItemBase {
	kind: 'hazard';
	hazard: Hazard;
}

export interface AlertTimelineItem extends TimelineItemBase {
	kind: 'alert';
	alert: Alert;
}

export type TimelineItem = EarthquakeTimelineItem | HazardTimelineItem | AlertTimelineItem;

export interface TimelinePage {
	items: TimelineItem[];
	next_cursor: string | null;
	generated_at: string;
}

export type TimelineMinMagnitude = 'all' | 2.5 | 4.5;

export type TimelineMinSeverity = 'all' | 'moderate' | 'severe' | 'extreme';

export interface TimelineFilters {
	kinds: Set<TimelineKind>;
	minMagnitude: TimelineMinMagnitude;
	minSeverity: TimelineMinSeverity;
}
