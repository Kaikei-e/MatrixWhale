import { browser } from '$app/environment';

export type Theme = 'day' | 'night';

function readTheme(): Theme {
	return browser && document.documentElement.dataset.theme === 'night' ? 'night' : 'day';
}

class ThemeState {
	current = $state<Theme>(readTheme());

	constructor() {
		if (!browser) return;
		const observer = new MutationObserver(() => {
			this.current = readTheme();
		});
		observer.observe(document.documentElement, {
			attributes: true,
			attributeFilter: ['data-theme']
		});
	}
}

export const themeState = new ThemeState();
