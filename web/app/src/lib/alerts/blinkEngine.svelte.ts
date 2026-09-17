import { RHYTHM_KEYS, rhythmLit, type Rhythm } from './blinkBucket';

export type BlinkPhase = Record<Rhythm, boolean>;

// One rAF loop turns the clock into a lit/dim flag per rhythm. Only flips are
// assigned, so downstream paint updates happen a few times a second, not per frame.
export class BlinkEngine {
	phase = $state<BlinkPhase>({ q: false, fl2: false, fl4: false });
	#frame: number | null = null;

	get running(): boolean {
		return this.#frame !== null;
	}

	start(): void {
		if (this.#frame !== null) return;
		const tick = (now: number) => {
			for (const rhythm of RHYTHM_KEYS) {
				const lit = rhythmLit(rhythm, now);
				if (this.phase[rhythm] !== lit) this.phase[rhythm] = lit;
			}
			this.#frame = requestAnimationFrame(tick);
		};
		this.#frame = requestAnimationFrame(tick);
	}

	stop(): void {
		if (this.#frame !== null) cancelAnimationFrame(this.#frame);
		this.#frame = null;
	}
}
