export class BlinkEngine {
	t = $state(0);
	#frame: number | null = null;

	get running(): boolean {
		return this.#frame !== null;
	}

	start(): void {
		if (this.#frame !== null) return;
		const tick = (now: number) => {
			this.t = now;
			this.#frame = requestAnimationFrame(tick);
		};
		this.#frame = requestAnimationFrame(tick);
	}

	stop(): void {
		if (this.#frame !== null) cancelAnimationFrame(this.#frame);
		this.#frame = null;
	}
}
