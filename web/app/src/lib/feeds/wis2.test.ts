import { describe, expect, it } from 'vitest';
import {
	computeTotalFailures,
	computeUnique24h,
	sortWis2Channels,
	type Wis2ChannelHealth
} from './wis2';

describe('WIS2 Feeds Helpers', () => {
	describe('computeUnique24h', () => {
		it('returns received minus duplicates', () => {
			expect(computeUnique24h(100, 15)).toBe(85);
			expect(computeUnique24h(50, 0)).toBe(50);
		});

		it('floors result at 0 if duplicates exceed received', () => {
			expect(computeUnique24h(10, 20)).toBe(0);
			expect(computeUnique24h(0, 5)).toBe(0);
		});
	});

	describe('computeTotalFailures', () => {
		it('sums download, decode, and integrity failure counts', () => {
			expect(computeTotalFailures(2, 3, 5)).toBe(10);
			expect(computeTotalFailures(0, 0, 0)).toBe(0);
			expect(computeTotalFailures(10, 0, 1)).toBe(11);
		});
	});

	describe('sortWis2Channels', () => {
		const sampleChannels: Wis2ChannelHealth[] = [
			{
				centre_id: 'dwd',
				kind: 'synop',
				received_24h: 1200,
				duplicates_24h: 200,
				download_failed_24h: 1,
				decode_failed_24h: 2,
				integrity_failed_24h: 0,
				last_received_at: '2026-09-25T12:00:00Z',
				status: 'ok'
			},
			{
				centre_id: 'ecmwf',
				kind: 'trajectory',
				received_24h: 50,
				duplicates_24h: 0,
				download_failed_24h: 5,
				decode_failed_24h: 0,
				integrity_failed_24h: 1,
				last_received_at: '2026-09-25T14:30:00Z',
				status: 'failing'
			},
			{
				centre_id: 'meteofrance',
				kind: 'warnings',
				received_24h: 300,
				duplicates_24h: 50,
				download_failed_24h: 0,
				decode_failed_24h: 0,
				integrity_failed_24h: 0,
				last_received_at: '2026-09-25T10:00:00Z',
				status: 'stale'
			}
		];

		it('sorts by centre_id ascending and descending', () => {
			const asc = sortWis2Channels(sampleChannels, 'centre_id', 'asc');
			expect(asc.map((c) => c.centre_id)).toEqual(['dwd', 'ecmwf', 'meteofrance']);

			const desc = sortWis2Channels(sampleChannels, 'centre_id', 'desc');
			expect(desc.map((c) => c.centre_id)).toEqual(['meteofrance', 'ecmwf', 'dwd']);
		});

		it('sorts by kind', () => {
			const asc = sortWis2Channels(sampleChannels, 'kind', 'asc');
			expect(asc.map((c) => c.kind)).toEqual(['synop', 'trajectory', 'warnings']);
		});

		it('sorts by unique_24h (received - duplicates)', () => {
			// dwd: 1000, ecmwf: 50, meteofrance: 250
			const asc = sortWis2Channels(sampleChannels, 'unique_24h', 'asc');
			expect(asc.map((c) => c.centre_id)).toEqual(['ecmwf', 'meteofrance', 'dwd']);

			const desc = sortWis2Channels(sampleChannels, 'unique_24h', 'desc');
			expect(desc.map((c) => c.centre_id)).toEqual(['dwd', 'meteofrance', 'ecmwf']);
		});

		it('sorts by duplicates_24h', () => {
			// dwd: 200, ecmwf: 0, meteofrance: 50
			const asc = sortWis2Channels(sampleChannels, 'duplicates_24h', 'asc');
			expect(asc.map((c) => c.centre_id)).toEqual(['ecmwf', 'meteofrance', 'dwd']);

			const desc = sortWis2Channels(sampleChannels, 'duplicates_24h', 'desc');
			expect(desc.map((c) => c.centre_id)).toEqual(['dwd', 'meteofrance', 'ecmwf']);
		});

		it('sorts by total failures', () => {
			// dwd: 3, ecmwf: 6, meteofrance: 0
			const asc = sortWis2Channels(sampleChannels, 'failures', 'asc');
			expect(asc.map((c) => c.centre_id)).toEqual(['meteofrance', 'dwd', 'ecmwf']);

			const desc = sortWis2Channels(sampleChannels, 'failures', 'desc');
			expect(desc.map((c) => c.centre_id)).toEqual(['ecmwf', 'dwd', 'meteofrance']);
		});

		it('sorts by last_received_at', () => {
			// dwd: 12:00, ecmwf: 14:30, meteofrance: 10:00
			const asc = sortWis2Channels(sampleChannels, 'last_received_at', 'asc');
			expect(asc.map((c) => c.centre_id)).toEqual(['meteofrance', 'dwd', 'ecmwf']);

			const desc = sortWis2Channels(sampleChannels, 'last_received_at', 'desc');
			expect(desc.map((c) => c.centre_id)).toEqual(['ecmwf', 'dwd', 'meteofrance']);
		});

		it('sorts by status', () => {
			// failing, ok, stale
			const asc = sortWis2Channels(sampleChannels, 'status', 'asc');
			expect(asc.map((c) => c.status)).toEqual(['failing', 'ok', 'stale']);
		});
	});
});
