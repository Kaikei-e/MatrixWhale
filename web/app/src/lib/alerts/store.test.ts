import { describe, it, expect } from 'vitest';
import { AlertStore, nextBlinkAfterArrival } from './store.svelte';
import type { Alert } from './types';

function makeAlert(overrides: Partial<Alert>): Alert {
	return {
		id: 'a1',
		event: 'Tornado Warning',
		severity: 'Extreme',
		urgency: 'Immediate',
		certainty: 'Observed',
		message_type: null,
		headline: null,
		area_desc: 'Test Area',
		ugc: [],
		same: [],
		geometry: null,
		sent: '2026-09-17T00:00:00Z',
		effective: null,
		expires: null,
		ends: null,
		first_seen_at: '2026-09-17T00:00:00Z',
		last_seen_at: '2026-09-17T00:00:00Z',
		ended_at: null,
		...overrides
	};
}

describe('nextBlinkAfterArrival', () => {
	it('is persistent for Extreme when not acknowledged', () => {
		expect(nextBlinkAfterArrival('Extreme', false)).toBe('persistent');
	});

	it('is persistent for Severe when not acknowledged', () => {
		expect(nextBlinkAfterArrival('Severe', false)).toBe('persistent');
	});

	it('is static for Moderate/Minor/Unknown regardless of acknowledgement', () => {
		expect(nextBlinkAfterArrival('Moderate', false)).toBe('static');
		expect(nextBlinkAfterArrival('Minor', false)).toBe('static');
		expect(nextBlinkAfterArrival('Unknown', false)).toBe('static');
	});

	it('is static for any severity once acknowledged', () => {
		expect(nextBlinkAfterArrival('Extreme', true)).toBe('static');
		expect(nextBlinkAfterArrival('Severe', true)).toBe('static');
	});
});

describe('AlertStore derived state', () => {
	it('countsBySeverity counts active alerts per severity', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', severity: 'Extreme' }));
		store.activeAlerts.set('a2', makeAlert({ id: 'a2', severity: 'Extreme' }));
		store.activeAlerts.set('a3', makeAlert({ id: 'a3', severity: 'Minor' }));

		expect(store.countsBySeverity).toEqual({
			Extreme: 2,
			Severe: 0,
			Moderate: 0,
			Minor: 1,
			Unknown: 0
		});
	});

	it('zoneSeverity keeps the highest severity per UGC', () => {
		const store = new AlertStore();
		store.activeAlerts.set('a1', makeAlert({ id: 'a1', severity: 'Minor', ugc: ['OKC143'] }));
		store.activeAlerts.set('a2', makeAlert({ id: 'a2', severity: 'Extreme', ugc: ['OKC143'] }));

		expect(store.zoneSeverity.get('OKC143')).toBe('Extreme');
	});

	it('hasAnyBlinking is false when stopAll is set', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'arrival', until: 1000 });
		store.stopAll = true;

		expect(store.hasAnyBlinking).toBe(false);
	});

	it('hasAnyBlinking is false when reducedMotion is set', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'persistent', until: null });
		store.reducedMotion = true;

		expect(store.hasAnyBlinking).toBe(false);
	});

	it('hasAnyBlinking is true when an alert is arriving/persistent/updating', () => {
		const store = new AlertStore();
		store.blink.set('a1', { mode: 'static', until: null });
		store.blink.set('a2', { mode: 'update', until: 500 });

		expect(store.hasAnyBlinking).toBe(true);
	});

	it('sorted orders active alerts by NWS priority', () => {
		const store = new AlertStore();
		store.activeAlerts.set(
			'a1',
			makeAlert({ id: 'a1', event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' })
		);
		store.activeAlerts.set(
			'a2',
			makeAlert({ id: 'a2', event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' })
		);

		expect(store.sorted.map((a) => a.id)).toEqual(['a2', 'a1']);
	});
});
