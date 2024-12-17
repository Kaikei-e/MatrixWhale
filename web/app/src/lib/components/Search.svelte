<script lang="ts">
	import type { NoaaSeverityData } from '$lib/types/noaa';
	import type { PageData, ActionData } from '../../routes/superforms/noaa_area/$types';

	const matrixWhaleUrl = import.meta.env.VITE_MATRIX_WHALE_FETCH_URL;

	let { objectForSearch }: { objectForSearch: { data: PageData; form: ActionData } } = $props();

	let areaDescription = $state('');
	let loading = $state(false);

	async function search(event: SubmitEvent & { currentTarget: EventTarget & HTMLFormElement }) {
		event.preventDefault();
		loading = true;

		const targetURL = new URL('/api/v1/noaa_data/search_area_description', matrixWhaleUrl);
		const response = await fetch(targetURL, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Accept: 'application/json'
			},
			body: JSON.stringify({ areaDescription: areaDescription })
		});

		if (!response.ok) {
			throw new Error(`API responded with status ${response.status}`);
		}

		const noaaSeverityList: NoaaSeverityData[] = await response.json();

		objectForSearch.data.noaaSeverityData = noaaSeverityList;
		loading = false;
		return {
			noaaSeverityData: noaaSeverityList
		};
	}
</script>

<div class="h-full w-full">
	<form method="POST" onsubmit={search} class="flex w-full flex-col gap-4">
		<div class="flex flex-col gap-2">
			<label for="areaDescription" class="text-sm font-medium text-gray-700">
				Search Alerts Area By Words
			</label>
			<input
				type="text"
				id="areaDescription"
				name="areaDescription"
				value={areaDescription}
				oninput={(e) => (areaDescription = e.currentTarget.value)}
				class="w-full rounded-md border border-gray-300 px-3 py-2 focus:border-blue-500"
				required
			/>
		</div>
		<button
			type="submit"
			class="rounded-md bg-blue-500 px-4 py-2 text-white hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
			disabled={loading}
		>
			<span>Search</span>
		</button>
	</form>
	<div class="flex h-[calc(100%-8rem)] flex-col overflow-y-auto">
		{#if !loading && objectForSearch?.data?.noaaSeverityData && objectForSearch?.data?.noaaSeverityData.length === 0}
			<p class="text-red-400">No data found</p>
		{:else if loading}
			<div class="flex justify-center">
				<div
					class="mt-4 h-5 w-5 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else if !loading && objectForSearch?.data?.noaaSeverityData && objectForSearch?.data?.noaaSeverityData.length > 0}
			<div class="mt-4 flex w-full flex-col gap-2">
				{#each objectForSearch?.data?.noaaSeverityData as alert}
					<div class="rounded-lg border p-4 shadow-sm">
						<p class="text-lg font-medium">Area: {alert.area_desc}</p>
						<p class="text-sm text-gray-600">Severity: {alert.severity}</p>
					</div>
				{/each}
			</div>
		{:else}
			<div class="mt-4 flex justify-center">
				<div class="flex h-5/6 w-5/6 flex-row items-center justify-center">
					<p>Waiting for data...</p>
				</div>
			</div>
		{/if}
	</div>
</div>
