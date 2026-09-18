import { describe, it, expect } from 'vitest';
import { ScrollMemory } from './scroll';

describe('ScrollMemory', () => {
	it('recalls 0 for a key that was never remembered', () => {
		const memory = new ScrollMemory();
		expect(memory.recall('earthquakes')).toBe(0);
	});

	it('recalls the last remembered value for a key', () => {
		const memory = new ScrollMemory();
		memory.remember('earthquakes', 120);
		expect(memory.recall('earthquakes')).toBe(120);
	});

	it('overwrites a previously remembered value', () => {
		const memory = new ScrollMemory();
		memory.remember('hazards', 40);
		memory.remember('hazards', 90);
		expect(memory.recall('hazards')).toBe(90);
	});

	it('keeps positions independent per key', () => {
		const memory = new ScrollMemory();
		memory.remember('earthquakes', 30);
		memory.remember('hazards', 70);
		expect(memory.recall('earthquakes')).toBe(30);
		expect(memory.recall('hazards')).toBe(70);
	});

	it('clear resets a key back to 0', () => {
		const memory = new ScrollMemory();
		memory.remember('alerts', 55);
		memory.clear('alerts');
		expect(memory.recall('alerts')).toBe(0);
	});
});
