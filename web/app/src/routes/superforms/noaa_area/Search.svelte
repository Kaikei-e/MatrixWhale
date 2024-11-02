<script lang="ts">
	import { invalidateAll } from '$app/navigation';
	import { applyAction, deserialize } from '$app/forms';
	import type { ActionResult } from '@sveltejs/kit';

	const matrixWhaleUrlBasePath = import.meta.env.VITE_MATRIX_WHALE_URL;
	let searchWord: string;

	const handleSubmit = async (event: SubmitEvent) => {
		event.preventDefault();
		const form = event.target as HTMLFormElement;
		const formData = new FormData(form);

		// Convert FormData to JSON
		const jsonData = {
			areaDescription: formData.get('areaDescription')
		};

		const targetUrl = new URL('/api/v1/noaa_data/search_area_description', matrixWhaleUrlBasePath);

		try {
			const response = await fetch(targetUrl, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Accept: 'application/json'
				},
				body: JSON.stringify(jsonData)
			});

			const result: ActionResult = deserialize(await response.text());
			if (result.type === 'success') {
				await invalidateAll();
			}
			applyAction(result);
		} catch (error) {
			console.error('Submit error:', error);
		}
	};
</script>

<div class="w-full">
	<form method="POST" on:submit={handleSubmit} class="flex w-full flex-col gap-4">
		<div class="flex flex-col gap-2">
			<label for="areaDescription" class="text-sm font-medium text-gray-700">
				Search Alerts Area By Words
			</label>
			<input
				type="text"
				id="areaDescription"
				name="areaDescription"
				bind:value={searchWord}
				class="w-full rounded-md border border-gray-300 px-3 py-2 focus:border-blue-500 focus:outline-none"
			/>
		</div>
		<button
			type="submit"
			class="rounded-md bg-blue-500 px-4 py-2 text-white hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
		>
			Search
		</button>
	</form>
</div>
