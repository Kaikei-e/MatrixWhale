import { describe, it, expect } from 'vitest';
import { sortByNwsPriority } from './priority';

describe('sortByNwsPriority', () => {
	it('orders by NWS priority ascending, unknown events last', () => {
		const alerts = [
			{ event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' },
			{ event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' },
			{ event: 'Something Unlisted', sent: '2026-09-17T11:00:00Z' },
			{ event: 'Severe Thunderstorm Warning', sent: '2026-09-17T08:00:00Z' }
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
			{ event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' },
			{ event: 'Tornado Warning', sent: '2026-09-17T11:00:00Z' }
		];

		const sorted = sortByNwsPriority(alerts);

		expect(sorted.map((a) => a.sent)).toEqual(['2026-09-17T11:00:00Z', '2026-09-17T09:00:00Z']);
	});

	it('does not mutate the input array', () => {
		const alerts = [
			{ event: 'Flood Advisory', sent: '2026-09-17T10:00:00Z' },
			{ event: 'Tornado Warning', sent: '2026-09-17T09:00:00Z' }
		];
		const copy = [...alerts];

		sortByNwsPriority(alerts);

		expect(alerts).toEqual(copy);
	});
});
