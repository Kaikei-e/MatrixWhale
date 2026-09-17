// UI text is English by default (project convention), so formatting must not
// follow the browser's locale even though it stays in the viewer's local time zone.
const LOCALE = 'en-US';

export function formatLocalDateTime(iso: string, timeZone?: string): string {
	return new Date(iso).toLocaleString(LOCALE, {
		dateStyle: 'medium',
		timeStyle: 'short',
		...(timeZone ? { timeZone } : {})
	});
}

export function formatLocalHour(iso: string, timeZone?: string): string {
	return new Date(iso).toLocaleString(LOCALE, {
		hour: 'numeric',
		hour12: true,
		...(timeZone ? { timeZone } : {})
	});
}
