<script lang="ts">
	import type { Alert } from '$lib/alerts/types';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';

	interface Props {
		alert: Alert;
		onclose: () => void;
		onacknowledge: () => void;
	}

	let { alert, onclose, onacknowledge }: Props = $props();

	function formatExpires(iso: string): string {
		const local = formatLocalDateTime(iso);
		const minutes = Math.round((new Date(iso).getTime() - Date.now()) / 60000);
		if (minutes <= 0) return `Expired · ${local}`;
		if (minutes < 60) return `Expires in ${minutes}m · ${local}`;
		const hours = Math.round(minutes / 60);
		return `Expires in ${hours}h · ${local}`;
	}
</script>

<div class="border-ink-2/30 flex flex-col gap-2 border-b px-3 py-3 text-sm">
	<div class="flex items-start justify-between gap-2">
		<h2 class="text-base font-semibold">{alert.event}</h2>
		<button
			type="button"
			onclick={onclose}
			aria-label="Close details"
			class="text-ink-2 hover:text-ink"
		>
			&times;
		</button>
	</div>

	<p class="text-ink-2 tabular text-xs">{alert.severity} · {alert.urgency} · {alert.certainty}</p>

	{#if alert.headline}
		<p>{alert.headline}</p>
	{/if}

	<p class="text-ink-2">{alert.area_desc}</p>

	{#if alert.expires}
		<p class="tabular text-xs">
			<time datetime={alert.expires} title={alert.expires}>{formatExpires(alert.expires)}</time>
		</p>
	{/if}

	<div class="flex items-center gap-2 pt-1">
		<a
			href="https://api.weather.gov/alerts/{alert.id}"
			target="_blank"
			rel="noopener noreferrer"
			class="border-ink-2/30 hover:bg-shoal border px-2 py-1 text-xs"
		>
			NWS source
		</a>
		<button
			type="button"
			onclick={onacknowledge}
			class="border-ink-2/30 hover:bg-shoal border px-2 py-1 text-xs"
		>
			Acknowledge
		</button>
	</div>
</div>
