import type { AlertLevel } from '$lib/hazards/types';
import type { Severity } from '$lib/alerts/types';
import type { Theme } from '$lib/theme.svelte';

/** Compact row-meta time: "now", "15m", "2h", "3d" — never longer than 3 chars. */
export function formatShortRelativeTime(iso: string, now: number = Date.now()): string {
	const minutes = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
	if (minutes < 1) return 'now';
	if (minutes < 60) return `${minutes}m`;
	const hours = Math.round(minutes / 60);
	if (hours < 24) return `${hours}h`;
	return `${Math.round(hours / 24)}d`;
}

export function formatBadgeCount(count: number): string {
	return count > 999 ? '999+' : String(count);
}

export function magnitudeLabel(magnitude: number | null): string {
	return magnitude === null ? 'M—' : `M${magnitude.toFixed(1)}`;
}

/** Same tiering as the map's blink rhythm (fl4/fl2/group), read as a 3-level severity. */
export function earthquakeSeverity(magnitude: number | null): AlertLevel {
	const value = magnitude ?? Number.NEGATIVE_INFINITY;
	if (value < 4.5) return 'green';
	if (value < 6) return 'orange';
	return 'red';
}

export function alertSeverityLevel(severity: Severity): AlertLevel {
	if (severity === 'Extreme' || severity === 'Severe') return 'red';
	if (severity === 'Moderate') return 'orange';
	return 'green';
}

export function levelLetter(level: AlertLevel): string {
	return level.charAt(0).toUpperCase();
}

// GDACS orange (#ef6c00) is only 2.9:1 against the day --paper (#f7f9f6), below the
// 3:1 WCAG 1.4.11 floor for a graphical severity dot; darkened for day only (measured
// at 3.58:1). Night keeps the original hex (5.67:1 against night --paper already).
const LEVEL_DOT_COLORS: Record<Theme, Record<AlertLevel, string>> = {
	day: { green: '#2e7d32', orange: '#d46200', red: '#c62828' },
	night: { green: '#2e7d32', orange: '#ef6c00', red: '#c62828' }
};

export function levelDotColor(level: AlertLevel, theme: Theme): string {
	return LEVEL_DOT_COLORS[theme][level];
}
