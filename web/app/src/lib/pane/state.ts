export const PANE_TABS = ['earthquakes', 'hazards', 'alerts', 'feed'] as const;

export type PaneTab = (typeof PANE_TABS)[number];

export const PANE_TAB_LABELS: Record<PaneTab, string> = {
	earthquakes: 'Earthquakes',
	hazards: 'Hazards',
	alerts: 'Alerts',
	feed: 'Feed'
};

const STORAGE_KEY = 'globe.sidePane.activeTab';

function isPaneTab(value: unknown): value is PaneTab {
	return typeof value === 'string' && (PANE_TABS as readonly string[]).includes(value);
}

/** Reads the persisted tab defensively: private mode / blocked storage must not break the pane. */
export function loadStoredTab(
	storage: Pick<Storage, 'getItem'> | null | undefined
): PaneTab | null {
	if (!storage) return null;
	try {
		const value = storage.getItem(STORAGE_KEY);
		return isPaneTab(value) ? value : null;
	} catch {
		return null;
	}
}

export function storeTab(storage: Pick<Storage, 'setItem'> | null | undefined, tab: PaneTab): void {
	if (!storage) return;
	try {
		storage.setItem(STORAGE_KEY, tab);
	} catch {
		// Quota/private-mode errors must not block switching tabs in-memory.
	}
}

export function nextTabIndex(current: number, direction: 1 | -1, length: number): number {
	return (current + direction + length) % length;
}

export type SelectionKind = 'earthquake' | 'hazard' | 'alert';

// Alerts can drill in from either the Alerts or the legacy Feed tab; earthquakes
// and hazards each own exactly one tab.
const TAB_CANDIDATES: Record<SelectionKind, readonly PaneTab[]> = {
	earthquake: ['earthquakes'],
	hazard: ['hazards'],
	alert: ['alerts', 'feed']
};

export interface TabResolution {
	tab: PaneTab;
	switched: boolean;
}

export function resolveTabForSelection(activeTab: PaneTab, kind: SelectionKind): TabResolution {
	const candidates = TAB_CANDIDATES[kind];
	if (candidates.includes(activeTab)) return { tab: activeTab, switched: false };
	return { tab: candidates[0], switched: true };
}

export interface DetailSelection {
	earthquakeId: number | null;
	hazardId: string | null;
	alertId: string | null;
}

/** Whether the currently active tab is showing a drill-in detail (vs. its list). */
export function isDetailOpen(activeTab: PaneTab, selection: DetailSelection): boolean {
	if (activeTab === 'earthquakes') return selection.earthquakeId !== null;
	if (activeTab === 'hazards') return selection.hazardId !== null;
	return selection.alertId !== null;
}

/** Which selection kind a tab's Escape/back action would close. */
export function closeKindForTab(tab: PaneTab): SelectionKind {
	if (tab === 'earthquakes') return 'earthquake';
	if (tab === 'hazards') return 'hazard';
	return 'alert';
}
