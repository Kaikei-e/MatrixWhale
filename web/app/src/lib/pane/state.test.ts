import { describe, it, expect, vi } from 'vitest';
import {
	PANE_TABS,
	PANE_TAB_LABELS,
	loadStoredTab,
	storeTab,
	nextTabIndex,
	resolveTabForSelection,
	isDetailOpen,
	closeKindForTab
} from './state';

function fakeStorage(initial: Record<string, string> = {}): Storage {
	const data = new Map(Object.entries(initial));
	return {
		getItem: (key: string) => data.get(key) ?? null,
		setItem: (key: string, value: string) => {
			data.set(key, value);
		},
		removeItem: (key: string) => data.delete(key),
		clear: () => data.clear(),
		key: () => null,
		length: data.size
	} as Storage;
}

describe('PANE_TABS / PANE_TAB_LABELS', () => {
	it('has a label for every tab', () => {
		for (const tab of PANE_TABS) expect(PANE_TAB_LABELS[tab]).toBeTruthy();
	});
});

describe('loadStoredTab', () => {
	it('returns null when storage is missing', () => {
		expect(loadStoredTab(null)).toBeNull();
		expect(loadStoredTab(undefined)).toBeNull();
	});

	it('returns null when nothing is stored', () => {
		expect(loadStoredTab(fakeStorage())).toBeNull();
	});

	it('returns the stored tab when it is valid', () => {
		const storage = fakeStorage({ 'globe.sidePane.activeTab': 'hazards' });
		expect(loadStoredTab(storage)).toBe('hazards');
	});

	it('returns null for a value that is not a known tab', () => {
		const storage = fakeStorage({ 'globe.sidePane.activeTab': 'bogus' });
		expect(loadStoredTab(storage)).toBeNull();
	});

	it('swallows a throwing storage and returns null', () => {
		const storage = {
			getItem: () => {
				throw new Error('blocked');
			}
		} as unknown as Storage;
		expect(loadStoredTab(storage)).toBeNull();
	});
});

describe('storeTab', () => {
	it('writes the tab under the storage key', () => {
		const storage = fakeStorage();
		storeTab(storage, 'alerts');
		expect(storage.getItem('globe.sidePane.activeTab')).toBe('alerts');
	});

	it('does nothing when storage is missing', () => {
		expect(() => storeTab(null, 'alerts')).not.toThrow();
	});

	it('swallows a throwing storage', () => {
		const storage = {
			setItem: vi.fn(() => {
				throw new Error('quota exceeded');
			})
		} as unknown as Storage;
		expect(() => storeTab(storage, 'feed')).not.toThrow();
	});
});

describe('nextTabIndex', () => {
	it('advances forward and wraps at the end', () => {
		expect(nextTabIndex(0, 1, 4)).toBe(1);
		expect(nextTabIndex(3, 1, 4)).toBe(0);
	});

	it('advances backward and wraps at the start', () => {
		expect(nextTabIndex(1, -1, 4)).toBe(0);
		expect(nextTabIndex(0, -1, 4)).toBe(3);
	});
});

describe('resolveTabForSelection', () => {
	it('keeps the active tab when it already owns the selection kind', () => {
		expect(resolveTabForSelection('earthquakes', 'earthquake')).toEqual({
			tab: 'earthquakes',
			switched: false
		});
		expect(resolveTabForSelection('hazards', 'hazard')).toEqual({
			tab: 'hazards',
			switched: false
		});
		expect(resolveTabForSelection('alerts', 'alert')).toEqual({ tab: 'alerts', switched: false });
		expect(resolveTabForSelection('feed', 'alert')).toEqual({ tab: 'feed', switched: false });
	});

	it('switches to the home tab when the active tab does not own the kind', () => {
		expect(resolveTabForSelection('hazards', 'earthquake')).toEqual({
			tab: 'earthquakes',
			switched: true
		});
		expect(resolveTabForSelection('earthquakes', 'hazard')).toEqual({
			tab: 'hazards',
			switched: true
		});
		expect(resolveTabForSelection('earthquakes', 'alert')).toEqual({
			tab: 'alerts',
			switched: true
		});
	});
});

describe('isDetailOpen', () => {
	const none = { earthquakeId: null, hazardId: null, alertId: null };

	it('is true only when the active tab owns a non-null selection', () => {
		expect(isDetailOpen('earthquakes', { ...none, earthquakeId: 1 })).toBe(true);
		expect(isDetailOpen('hazards', { ...none, hazardId: 'gdacs:1' })).toBe(true);
		expect(isDetailOpen('alerts', { ...none, alertId: 'urn:1' })).toBe(true);
		expect(isDetailOpen('feed', { ...none, alertId: 'urn:1' })).toBe(true);
	});

	it('is false when nothing is selected', () => {
		expect(isDetailOpen('earthquakes', none)).toBe(false);
		expect(isDetailOpen('hazards', none)).toBe(false);
		expect(isDetailOpen('alerts', none)).toBe(false);
		expect(isDetailOpen('feed', none)).toBe(false);
	});

	it('is false when the active tab does not own the selected kind', () => {
		expect(isDetailOpen('earthquakes', { ...none, hazardId: 'gdacs:1' })).toBe(false);
		expect(isDetailOpen('hazards', { ...none, earthquakeId: 1 })).toBe(false);
		expect(isDetailOpen('earthquakes', { ...none, alertId: 'urn:1' })).toBe(false);
	});
});

describe('closeKindForTab', () => {
	it('maps each tab to the selection kind it can close', () => {
		expect(closeKindForTab('earthquakes')).toBe('earthquake');
		expect(closeKindForTab('hazards')).toBe('hazard');
		expect(closeKindForTab('alerts')).toBe('alert');
		expect(closeKindForTab('feed')).toBe('alert');
	});
});
