import { describe, it, expect } from 'vitest';
import { sortByNwsPriority } from './priority';

describe('sortByNwsPriority', () => {
	it('orders by NWS priority ascending, unknown events last', () => {
		const alerts = [
			{ source: 'noaa', event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' },
			{ source: 'noaa', event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' },
			{ source: 'noaa', event: 'Something Unlisted', sent: '2026-09-17T11:00:00Z' },
			{ source: 'noaa', event: 'Severe Thunderstorm Warning', sent: '2026-09-17T08:00:00Z' }
		];

		const sorted = sortByNwsPriority(alerts);

		expect(sorted.map((a) => a.event)).toEqual([
			'Tornado Warning',
			'Severe Thunderstorm Warning',
			'Flood Advisory',
			'Something Unlisted'
		]);
	});

	it('breaks ties within the same priority by sent desc', () => {
		const alerts = [
			{ source: 'noaa', event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' },
			{ source: 'noaa', event: 'Tornado Warning', sent: '2026-09-17T11:00:00Z' }
		];

		const sorted = sortByNwsPriority(alerts);

		expect(sorted.map((a) => a.sent)).toEqual(['2026-09-17T11:00:00Z', '2026-09-17T09:00:00Z']);
	});

	it('orders CAP events by severity -> urgency -> time desc', () => {
		const capAlerts = [
			{
				source: 'cap-deu',
				event: 'wind gusts',
				severity: 'Moderate',
				urgency: 'Immediate',
				sent: '2026-09-19T10:00:00Z'
			},
			{
				source: 'cap-fra',
				event: 'inondation',
				severity: 'Extreme',
				urgency: 'Expected',
				sent: '2026-09-19T08:00:00Z'
			},
			{
				source: 'cap-gbr',
				event: 'heavy rain',
				severity: 'Severe',
				urgency: 'Immediate',
				sent: '2026-09-19T09:00:00Z'
			},
			{
				source: 'cap-esp',
				event: 'viento',
				severity: 'Severe',
				urgency: 'Expected',
				sent: '2026-09-19T09:30:00Z'
			},
			{
				source: 'cap-ita',
				event: 'pioggia',
				severity: 'Severe',
				urgency: 'Immediate',
				sent: '2026-09-19T09:30:00Z'
			}
		];

		const sorted = sortByNwsPriority(capAlerts);
		expect(sorted.map((a) => a.event)).toEqual([
			'inondation', // Extreme
			'pioggia', // Severe, Immediate, 09:30
			'heavy rain', // Severe, Immediate, 09:00
			'viento', // Severe, Expected, 09:30
			'wind gusts' // Moderate
		]);
	});

	it('orders mixed NOAA and CAP alerts: severity ranks first across sources', () => {
		const mixed = [
			{
				source: 'noaa',
				event: 'Frost Advisory',
				severity: 'Minor',
				urgency: 'Expected',
				sent: '2026-09-19T08:00:00Z'
			},
			{
				source: 'cap-fra',
				event: 'tempête',
				severity: 'Extreme',
				urgency: 'Immediate',
				sent: '2026-09-19T09:00:00Z'
			},
			{
				source: 'noaa',
				event: 'Tornado Warning',
				severity: 'Extreme',
				urgency: 'Immediate',
				sent: '2026-09-19T09:30:00Z'
			},
			{
				source: 'cap-deu',
				event: 'Starkregen',
				severity: 'Moderate',
				urgency: 'Immediate',
				sent: '2026-09-19T10:00:00Z'
			}
		];

		const sorted = sortByNwsPriority(mixed);
		// Extreme alerts first (Tornado Warning & tempête), then Moderate (Starkregen), then Minor (Frost Advisory)
		expect(sorted[0].severity).toBe('Extreme');
		expect(sorted[1].severity).toBe('Extreme');
		expect(sorted[2].severity).toBe('Moderate');
		expect(sorted[3].severity).toBe('Minor');
	});

	it('does not mutate the input array', () => {
		const alerts = [
			{ source: 'noaa', event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' },
			{ source: 'noaa', event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' }
		];
		const copy = [...alerts];

		sortByNwsPriority(alerts);

		expect(alerts).toEqual(copy);
	});

	it('all permutations of a 3-element and 4-element mixed set yield the exact same total order', () => {
		function permutations<T>(arr: T[]): T[][] {
			if (arr.length <= 1) return [arr];
			const result: T[][] = [];
			for (let i = 0; i < arr.length; i++) {
				const current = arr[i];
				const remaining = [...arr.slice(0, i), ...arr.slice(i + 1)];
				for (const perm of permutations(remaining)) {
					result.push([current, ...perm]);
				}
			}
			return result;
		}

		const set4 = [
			{
				id: 'noaa:1',
				source: 'noaa',
				event: 'Tornado Warning',
				severity: 'Extreme',
				urgency: 'Immediate',
				sent: '2026-09-19T09:00:00Z'
			},
			{
				id: 'noaa:2',
				source: 'noaa',
				event: 'Flood Warning',
				severity: 'Severe',
				urgency: 'Expected',
				sent: '2026-09-19T10:00:00Z'
			},
			{
				id: 'cap:1',
				source: 'cap-fra',
				event: 'inondation',
				severity: 'Extreme',
				urgency: 'Immediate',
				sent: '2026-09-19T08:00:00Z'
			},
			{
				id: 'cap:2',
				source: 'cap-deu',
				event: 'wind',
				severity: 'Moderate',
				urgency: 'Immediate',
				sent: '2026-09-19T11:00:00Z'
			}
		];

		const expectedOrder = sortByNwsPriority(set4).map((a) => a.id);
		const perms4 = permutations(set4);
		expect(perms4.length).toBe(24);
		for (const perm of perms4) {
			expect(sortByNwsPriority(perm).map((a) => a.id)).toEqual(expectedOrder);
		}

		const set3 = set4.slice(0, 3);
		const expectedOrder3 = sortByNwsPriority(set3).map((a) => a.id);
		const perms3 = permutations(set3);
		expect(perms3.length).toBe(6);
		for (const perm of perms3) {
			expect(sortByNwsPriority(perm).map((a) => a.id)).toEqual(expectedOrder3);
		}
	});

	it('exact triple A (NOAA Tornado Warning Severe/Expected), B (NOAA Winter Weather Advisory Severe/Immediate), C (CAP Severe/Expected newer) forms a transitive total order across all permutations', () => {
		function permutations<T>(arr: T[]): T[][] {
			if (arr.length <= 1) return [arr];
			const result: T[][] = [];
			for (let i = 0; i < arr.length; i++) {
				const current = arr[i];
				const remaining = [...arr.slice(0, i), ...arr.slice(i + 1)];
				for (const perm of permutations(remaining)) {
					result.push([current, ...perm]);
				}
			}
			return result;
		}

		const triple = [
			{
				id: 'A',
				source: 'noaa',
				event: 'Tornado Warning',
				severity: 'Severe',
				urgency: 'Expected',
				sent: '2026-09-19T08:00:00Z'
			},
			{
				id: 'B',
				source: 'noaa',
				event: 'Winter Weather Advisory',
				severity: 'Severe',
				urgency: 'Immediate',
				sent: '2026-09-19T08:00:00Z'
			},
			{
				id: 'C',
				source: 'cap',
				event: 'Severe Storm',
				severity: 'Severe',
				urgency: 'Expected',
				sent: '2026-09-19T09:00:00Z'
			}
		];

		const expectedOrder = sortByNwsPriority(triple).map((a) => a.id);
		expect(expectedOrder).toEqual(['A', 'B', 'C']);
		const perms = permutations(triple);
		expect(perms.length).toBe(6);
		for (const perm of perms) {
			expect(sortByNwsPriority(perm).map((a) => a.id)).toEqual(['A', 'B', 'C']);
		}
	});
});
