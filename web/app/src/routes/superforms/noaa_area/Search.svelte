<script lang="ts">
	import { enhance } from '$app/forms';
	import type { PageData, ActionData } from './$types';

	let searchWord: string = $state('');

	const matrixWhaleUrlBasePath = import.meta.env.VITE_MATRIX_WHALE_URL;
	let { data, form }: { data: PageData; form: ActionData } = $props();

	let loading = $state(false);
</script>

<div class="w-full">
	<form method="POST" action="/superforms/noaa_area?/searchArea" use:enhance class="flex w-full flex-col gap-4">
		<div class="flex flex-col gap-2">
			<label for="areaDescription" class="text-sm font-medium text-gray-700">
				Search Alerts Area By Words
			</label>
			<input
				type="text"
				id="areaDescription"
				name="areaDescription"
				bind:value={searchWord}
				class="w-full rounded-md border border-gray-300 px-3 py-2 focus:border-blue-500"
			/>
		</div>
		<button
			type="submit"
			class="rounded-md bg-blue-500 px-4 py-2 text-white hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
		>
			Search
		</button>
	</form>
	<div class="flex flex-col justify-center">
		{#if loading}
			<div class="flex justify-center">
				<div
					class="h-10 w-10 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else if form?.noaaSeverityData?.searchArea !== undefined}
			<div class="flex justify-center">
				<div class="h-5 w-5">
					<p>{data?.noaaSeverityData.searchArea}</p>
				</div>
			</div>
		{:else}
			<div class="mt-4 flex justify-center">
				<div class="flex h-5/6 w-5/6 flex-row items-center justify-center">Waiting for input</div>
			</div>
		{/if}
	</div>
</div>
