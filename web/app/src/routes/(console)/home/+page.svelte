<script lang="ts">
	import PipelineRow from '$lib/components/PipelineRow.svelte';
	import ActiveBar from '$lib/components/ActiveBar.svelte';
	import Last24h from '$lib/components/Last24h.svelte';
	import SearchTable from '$lib/components/SearchTable.svelte';
</script>

<div class="h-full overflow-y-auto px-4 py-6">
	<h1 class="text-lg font-semibold">Console</h1>

	<section class="border-ink-2/30 mt-6 border-t pt-4">
		<h2 class="text-ink-2 text-xs tracking-wide uppercase">Pipeline</h2>
		<div class="mt-3">
			<PipelineRow />
		</div>
	</section>

	<section class="border-ink-2/30 mt-6 border-t pt-4">
		<h2 class="text-ink-2 text-xs tracking-wide uppercase">Active</h2>
		<div class="mt-3">
			<ActiveBar />
		</div>
	</section>

	<section class="border-ink-2/30 mt-6 border-t pt-4">
		<h2 class="text-ink-2 text-xs tracking-wide uppercase">Last 24h</h2>
		<div class="mt-3">
			<Last24h />
		</div>
	</section>

	<section class="border-ink-2/30 mt-6 border-t pt-4">
		<h2 class="text-ink-2 text-xs tracking-wide uppercase">Search</h2>
		<div class="mt-3">
			<SearchTable />
		</div>
	</section>
</div>
