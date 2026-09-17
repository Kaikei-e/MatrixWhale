import { describe, it, expect } from 'vitest';
import { REGION_PRESETS, bboxOfAlerts, initialViewBbox } from './presets';
import type { Alert } from '$lib/alerts/types';

function zoneAlert(id: string, ugc: string[]): Alert {
	return {
		id,
		event: 'Small Craft Advisory',
		severity: 'Minor',
		urgency: 'Expected',
		certainty: 'Likely',
		message_type: null,
		headline: null,
		area_desc: 'Test Area',
		ugc,
		same: [],
		geometry: null,
		sent: null,
		effective: null,
		expires: null,
		ends: null,
		first_seen_at: '2026-09-17T00:00:00Z',
		last_seen_at: '2026-09-17T00:00:00Z',
		ended_at: null
	};
}

const centroids: Record<string, [number, number]> = {
	MOZ001: [-94, 40],
	MOZ002: [-92, 38],
	PKZ001: [-170, 60],
	GUZ001: [145, 13]
};

describe('bboxOfAlerts', () => {
	it('spans every resolved point', () => {
		expect(bboxOfAlerts([zoneAlert('a', ['MOZ001', 'MOZ002'])], centroids)).toEqual([
			-94, 38, -92, 40
		]);
	});

	it('returns null when nothing resolves', () => {
		expect(bboxOfAlerts([zoneAlert('a', ['ZZZ999'])], centroids)).toBeNull();
	});
});

describe('initialViewBbox', () => {
	it('fits a compact set of alerts', () => {
		expect(initialViewBbox([zoneAlert('a', ['MOZ001', 'MOZ002'])], centroids)).toEqual([
			-94, 38, -92, 40
		]);
	});

	it('falls back to CONUS when the alerts span wider than CONUS', () => {
		const alerts = [
			zoneAlert('a', ['MOZ001']),
			zoneAlert('b', ['PKZ001']),
			zoneAlert('c', ['GUZ001'])
		];
		expect(initialViewBbox(alerts, centroids)).toBe(REGION_PRESETS.CONUS);
	});

	it('falls back to CONUS when no alert resolves', () => {
		expect(initialViewBbox([zoneAlert('a', ['ZZZ999'])], centroids)).toBe(REGION_PRESETS.CONUS);
	});
});
