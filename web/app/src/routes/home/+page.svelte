<script lang="ts">
	import { onMount } from 'svelte';
	import type { ActionData } from '../superforms/noaa_area/$types';
	import { initSeverityTypeReceiver, severityData } from '$lib/noaa_alerts/severity_type_reciever';
	import Search from '../superforms/noaa_area/Search.svelte';

	onMount(() => {
		console.log('Component mounted, initializing receiver...');
		const cleanup = initSeverityTypeReceiver();
		return () => {
			console.log('Component unmounting, cleaning up...');
			if (typeof cleanup === 'function') {
				cleanup();
			}
		};
	});
	let { form, data }: { form: FormData; data: ActionData } = $props();
	let searchWord = form?.get('areaDescription') as string;
</script>

<div class="h-screen w-screen bg-gradient-to-r from-indigo-300 to-blue-300 p-8">
	<div class="w-1/6">
		<p class="text-2xl text-black">Stats</p>
	</div>
	<div class="mt-8 grid h-5/6 w-full grid-flow-row-dense grid-cols-3 grid-rows-3 gap-4">
		<div class="col-span-2 rounded-lg border border-gray-200 bg-sky-100 p-4 shadow">
			{#if $severityData !== null}
				<h3 class="text-2xl text-black">{$severityData}</h3>
			{:else}
				<h3 class="text-2xl text-black">Waiting for data...</h3>
			{/if}
		</div>
		<div class="col-span-1 rounded-lg border border-gray-200 bg-sky-100 p-4 shadow">
			<Search {data} />
		</div>
		<div class="rounded-lg border border-gray-200 bg-sky-100 p-4 shadow">04</div>
		<div class="rounded-lg border border-gray-200 bg-sky-100 p-4 shadow">05</div>
	</div>
</div>
