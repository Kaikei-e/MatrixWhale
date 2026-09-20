import { expect, it, vi } from 'vitest';
import { waitForSnapshots, withSnapshotPriority } from './snapshotPriority';

it('holds map downloads until all concurrent snapshots complete or fail', async () => {
	let finish!: () => void;
	let fail!: (error: Error) => void;
	const first = withSnapshotPriority(
		() =>
			new Promise<void>((resolve) => {
				finish = resolve;
			})
	);
	const second = withSnapshotPriority(
		() =>
			new Promise<void>((_, reject) => {
				fail = reject;
			})
	);
	const caught = second.catch(() => undefined);
	let resumed = false;
	const map = waitForSnapshots().then(() => {
		resumed = true;
	});
	finish();
	await first;
	expect(resumed).toBe(false);
	fail(new Error('API unavailable'));
	await caught;
	await map;
	expect(resumed).toBe(true);
});

it('allows the map to load after 15 seconds even if a snapshot is stuck', async () => {
	vi.useFakeTimers();
	let finish!: () => void;
	const snapshot = withSnapshotPriority(
		() =>
			new Promise<void>((resolve) => {
				finish = resolve;
			})
	);
	try {
		let resumed = false;
		const map = waitForSnapshots().then(() => {
			resumed = true;
		});
		await vi.advanceTimersByTimeAsync(14_999);
		expect(resumed).toBe(false);
		await vi.advanceTimersByTimeAsync(1);
		await map;
		expect(resumed).toBe(true);
	} finally {
		finish();
		await snapshot;
		vi.useRealTimers();
	}
});
