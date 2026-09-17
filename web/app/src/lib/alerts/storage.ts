const ACKNOWLEDGED_KEY = 'alerts.acknowledged';
const THEME_KEY = 'theme';

export function loadAcknowledged(): Set<string> {
	try {
		const raw = localStorage.getItem(ACKNOWLEDGED_KEY);
		if (!raw) return new Set();
		return new Set(JSON.parse(raw));
	} catch {
		return new Set();
	}
}

export function saveAcknowledged(acknowledged: Set<string>): void {
	try {
		localStorage.setItem(ACKNOWLEDGED_KEY, JSON.stringify([...acknowledged]));
	} catch {
		// localStorage unavailable (private mode, quota, disabled) — acknowledgement is best-effort.
	}
}

export function loadFlag(key: string, fallback: boolean): boolean {
	try {
		const raw = localStorage.getItem(key);
		if (raw === null) return fallback;
		return raw === 'true';
	} catch {
		return fallback;
	}
}

export function saveFlag(key: string, value: boolean): void {
	try {
		localStorage.setItem(key, String(value));
	} catch {
		// localStorage unavailable — flag is best-effort.
	}
}

export function loadTheme(): 'day' | 'night' | null {
	try {
		const raw = localStorage.getItem(THEME_KEY);
		return raw === 'day' || raw === 'night' ? raw : null;
	} catch {
		return null;
	}
}

export function saveTheme(theme: 'day' | 'night'): void {
	try {
		localStorage.setItem(THEME_KEY, theme);
	} catch {
		// localStorage unavailable — theme falls back to the OS preference next load.
	}
}
