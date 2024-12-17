<script lang="ts">
	import { enhance } from '$app/forms';
	import type { PageData, ActionData } from './$types';

	let {
		object = { areaDescription: '' },
		data,
		form
	}: { object: { areaDescription: string }; data: PageData; form: ActionData } = $props();
	let loading = $state(false);
</script>

<div class="w-full">
	<form
		method="POST"
		action="/superforms/noaa_area?/search"
		use:enhance
		class="flex w-full flex-col gap-4"
	>
		<div class="flex flex-col gap-2">
			<label for="areaDescription" class="text-sm font-medium text-gray-700">
				Search Alerts Area By Words
			</label>
			<input
				type="text"
				id="areaDescription"
				name="areaDescription"
				value={object.areaDescription}
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
	<div class="flex flex-col justify-center">
		{#if !loading && data?.noaaSeverityData && data.noaaSeverityData.length === 0}
			<p class="text-red-400">No data found</p>
		{:else if loading}
			<div class="flex justify-center">
				<div
					class="mt-4 h-5 w-5 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else if !loading && data?.noaaSeverityData && data.noaaSeverityData.length > 0}
			<div class="mt-4 flex flex-col gap-2">
				{#each data.noaaSeverityData as alert}
					<div class="rounded-lg border p-4 shadow-sm">
						<p class="text-lg font-medium">Area: {alert.area_desc}</p>
						<p class="text-sm text-gray-600">Severity: {alert.severity}</p>
					</div>
				{/each}
			</div>
		{:else}
			<div class="mt-4 flex justify-center">
				<div class="flex h-5/6 w-5/6 flex-row items-center justify-center">
					<pre>{JSON.stringify({ data, form }, null, 2)}</pre>
				</div>
			</div>
		{/if}
	</div>
</div>
