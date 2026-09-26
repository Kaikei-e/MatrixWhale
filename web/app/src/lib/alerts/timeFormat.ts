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

/** Formats an ISO timestamp as compact "DD HH:mm" (e.g. "26 03:00") in local or given timezone. */
export function formatCompactDateTime(iso: string, timeZone?: string): string {
	const d = new Date(iso);
	if (isNaN(d.getTime())) return '—';
	const dtf = new Intl.DateTimeFormat(LOCALE, {
		day: '2-digit',
		hour: '2-digit',
		minute: '2-digit',
		hourCycle: 'h23',
		...(timeZone ? { timeZone } : {})
	});
	const parts = dtf.formatToParts(d);
	const day = parts.find((p) => p.type === 'day')?.value ?? '';
	const hour = parts.find((p) => p.type === 'hour')?.value ?? '';
	const minute = parts.find((p) => p.type === 'minute')?.value ?? '';
	return `${day} ${hour}:${minute}`;
}
