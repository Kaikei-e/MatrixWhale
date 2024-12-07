<script lang="ts">
	import Search from './Search.svelte';
	import type { PageData, ActionData } from './$types';
	import type { NoaaSeverityData } from '$lib/types/noaa';

	let { object } = $props();

	let data: PageData;
	let form: ActionData;
	let noaaSeverityData: NoaaSeverityData[] | null = null;

	$effect(() => {
		noaaSeverityData = form?.noaaSeverityData ?? null;
	});
</script>

<Search {object} {data} {form} />
