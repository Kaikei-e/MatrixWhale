<script lang="ts">
	import type { PageData, ActionData } from './$types';
	import { enhance } from '$app/forms';
	import type { NoaaSeverityData } from '$lib/types/noaa';

	let { data, form = undefined } = $props() as { data: PageData; form?: ActionData | undefined };
	let searchWord = $state('');
	let loading = $state(false);
	let noaaSeverityData: NoaaSeverityData[] | null = null;

	$effect(() => {
		console.log('data changed:', data);
		console.log('form changed:', form);
		console.log('noaaSeverityData changed:', noaaSeverityData);
	});
</script>

<div class="w-full">
	<form
		method="POST"
		action="/superforms/noaa_area?/search"
		use:enhance={() => {
			loading = true;

			return async ({ update }) => {
				await update();
				loading = false;
			};
		}}
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
				bind:value={searchWord}
				disabled={loading}
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
		{#if !loading && form?.noaaSeverityData && form.noaaSeverityData.length === 0}
			<p class="text-red-400">No data found</p>
		{:else if loading}
			<div class="flex justify-center">
				<div
					class="h-5 w-5 mt-4 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else if !loading && form?.noaaSeverityData && form.noaaSeverityData.length > 0}
			<div class="flex justify-center">
				<div class="h-5 w-5">
					<p>{form.noaaSeverityData[0].area_desc}</p>
				</div>
				<div class="h-5 w-5">
					<p>{form.noaaSeverityData[0].severity}</p>
				</div>
			</div>
		{:else if loading}
			<div class="flex justify-center">
				<div
					class="h-5 w-5 mt-4 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else}
			<div class="mt-4 flex justify-center">
				<div class="flex h-5/6 w-5/6 flex-row items-center justify-center">Waiting for input</div>
			</div>
		{/if}
	</div>
</div>
