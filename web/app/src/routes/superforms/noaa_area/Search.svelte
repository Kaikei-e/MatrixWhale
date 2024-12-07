<script lang="ts">
	import { enhance } from '$app/forms';

	let { object = { areaDescription: '' }, data, form } = $props();
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
		{#if !loading && form?.noaaSeverityData && form.noaaSeverityData.length === 0}
			<p class="text-red-400">No data found</p>
		{:else if loading}
			<div class="flex justify-center">
				<div
					class="mt-4 h-5 w-5 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
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
					class="mt-4 h-5 w-5 animate-spin rounded-full border-4 border-white border-b-transparent border-t-transparent"
				></div>
			</div>
		{:else}
			<div class="mt-4 flex justify-center">
				<div class="flex h-5/6 w-5/6 flex-row items-center justify-center">Waiting for input</div>
			</div>
		{/if}
	</div>
</div>
