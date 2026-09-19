<script lang="ts">
	import { resolve } from '$app/paths';
	import type { Alert } from '$lib/alerts/types';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';

	let query = $state('');
	let results = $state<Alert[]>([]);
	let error = $state<string | null>(null);
	let debounceTimer: ReturnType<typeof setTimeout> | undefined;

	async function search(): Promise<void> {
		if (!query.trim()) {
			results = [];
			error = null;
			return;
		}
		try {
			const response = await fetch(`/api/v1/alerts/search?q=${encodeURIComponent(query)}`);
			if (!response.ok) throw new Error(`status ${response.status}`);
			results = (await response.json()) as Alert[];
			error = null;
		} catch {
			error = 'Search unavailable.';
		}
	}

	function onInput(): void {
		if (debounceTimer) clearTimeout(debounceTimer);
		debounceTimer = setTimeout(search, 300);
	}
</script>

<div>
	<label class="flex flex-col gap-1 text-sm">
		<span class="text-ink-2">Search areas</span>
		<input
			type="search"
			bind:value={query}
			oninput={onInput}
			placeholder="e.g. Oklahoma County"
			class="border-ink-2/30 text-ink border bg-transparent px-2 py-1"
		/>
	</label>

	{#if error}
		<p class="text-ink-2 mt-2 text-sm">{error}</p>
	{:else if results.length > 0}
		<table class="tabular mt-3 w-full text-left text-sm">
			<thead>
				<tr class="border-ink-2/30 text-ink-2 border-b">
					<th class="py-1 font-normal">Event</th>
					<th class="py-1 font-normal">Severity</th>
					<th class="py-1 font-normal">Sent</th>
					<th class="py-1 font-normal">Expires</th>
					<th class="py-1 font-normal">Area</th>
				</tr>
			</thead>
			<tbody>
				{#each results as alert (alert.id)}
					<tr class="border-ink-2/10 border-b">
						<td class="py-1"
							><a
								href="{resolve('/globe')}?focus={encodeURIComponent(alert.id)}"
								class="hover:underline">{alert.event}</a
							></td
						>
						<td class="py-1">{alert.severity}</td>
						<td class="py-1">{alert.sent ? formatLocalDateTime(alert.sent) : '—'}</td>
						<td class="py-1">{alert.expires ? formatLocalDateTime(alert.expires) : '—'}</td>
						<td class="py-1">{alert.area_desc}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
</div>
