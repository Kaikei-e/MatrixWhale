// Large map files share the same constrained link as initial snapshots.
// Give snapshots a head start, with a bound so a failed API cannot hide the map.
let pending = 0;
const waiting = new Set<() => void>();

export async function withSnapshotPriority<T>(load: () => Promise<T>): Promise<T> {
	pending++;
	try {
		return await load();
	} finally {
		pending--;
		if (pending === 0) for (const resume of [...waiting]) resume();
	}
}

export function waitForSnapshots(): Promise<void> {
	if (pending === 0) return Promise.resolve();
	return new Promise((resolve) => {
		const resume = () => {
			clearTimeout(timer);
			waiting.delete(resume);
			resolve();
		};
		const timer = setTimeout(resume, 15_000);
		waiting.add(resume);
	});
}
