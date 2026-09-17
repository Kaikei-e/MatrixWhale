export interface ChartTokens {
	paper: string;
	land: string;
	shoal: string;
	ink: string;
	'ink-2': string;
	light: string;
	amber: string;
}

export const DAY: ChartTokens = {
	paper: '#f7f9f6',
	land: '#eadbb0',
	shoal: '#cfe2ea',
	ink: '#1c2a35',
	'ink-2': '#4a5c68',
	light: '#b8338f',
	amber: '#b45309'
};

export const NIGHT: ChartTokens = {
	paper: '#0f1b24',
	land: '#2a2f2b',
	shoal: '#16303d',
	ink: '#d5dee3',
	'ink-2': '#93a6b1',
	light: '#d46bb8',
	amber: '#fbbf24'
};

export function tokensFor(theme: 'day' | 'night'): ChartTokens {
	return theme === 'night' ? NIGHT : DAY;
}
