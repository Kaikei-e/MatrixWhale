<script lang="ts">
	import Search from './Search.svelte';
	import type { PageData, ActionData } from './$types';
	import type { NoaaSeverityData } from '$lib/types/noaa';

	let {
		object,
		data,
		form
	}: { object: { areaDescription: string }; data: PageData; form: ActionData } = $props();
	let noaaSeverityData: NoaaSeverityData[] | null = null;

	$effect(() => {
		noaaSeverityData = form?.noaaSeverityData ?? null;
	});
</script>

<Search {object} {data} {form} />
