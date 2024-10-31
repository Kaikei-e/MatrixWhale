<script lang="ts">
	import { invalidateAll, goto } from '$app/navigation';
	import { applyAction, deserialize } from '$app/forms';
	import type { ActionData } from './$types';
	import type { ActionResult } from '@sveltejs/kit';

	// let { form }: { form: ActionData } = $props();
	let { searchWord = $bindable('') } = $props<{ searchWord?: string }>();

	async function handleSubmit(event: { currentTarget: EventTarget & HTMLFormElement }) {
		const data = new FormData(event.currentTarget);

		const response = await fetch(event.currentTarget.action, {
			method: 'POST',
			body: data
		});

		const result: ActionResult = deserialize(await response.text());

		if (result.type === 'success') {
			// rerun all `load` functions, following the successful update
			await invalidateAll();
		}

		applyAction(result);
	}
</script>

<div class="flex flex-col">
	<form class="flex flex-col gap-2 bg-gray-50 p-4 rounded-lg" method="POST" on:submit|preventDefault={handleSubmit}>
		<label for="areaDescription">Search Alerts Area By Words</label>
		<input type="text" name="areaDescription" bind:value={searchWord} />
		<button type="submit">Search</button>
	</form>
</div>
