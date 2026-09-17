<script lang="ts">
	import { REGION_PRESETS, type Bbox } from '$lib/chart/presets';

	interface Props {
		onselect: (bbox: Bbox) => void;
	}

	let { onselect }: Props = $props();

	const PRESETS: [key: keyof typeof REGION_PRESETS, label: string][] = [
		['CONUS', 'CONUS'],
		['AK', 'AK'],
		['HI-Pac', 'HI/Pac'],
		['Carib', 'Carib']
	];
</script>

<div class="flex gap-1" role="group" aria-label="Region presets">
	{#each PRESETS as [key, label] (key)}
		<button
			type="button"
			onclick={() => onselect(REGION_PRESETS[key])}
			class="border-ink-2/30 bg-paper/90 text-ink hover:bg-shoal border px-2 py-1 text-sm"
		>
			{label}
		</button>
	{/each}
</div>
