/** Remembers each tab's list scrollTop across a list <-> detail drill-in swap. */
export class ScrollMemory {
	#positions = new Map<string, number>();

	remember(key: string, top: number): void {
		this.#positions.set(key, top);
	}

	recall(key: string): number {
		return this.#positions.get(key) ?? 0;
	}

	clear(key: string): void {
		this.#positions.delete(key);
	}
}
