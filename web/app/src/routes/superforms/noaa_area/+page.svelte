<script>
	import { superForm } from 'sveltekit-superforms';
	export let data;
	const { form, errors, constraints, message } = superForm(data.form);
</script>

{#if $message}
	<p>{$message}</p>
{/if}

<div class="flex flex-col gap-4">
	<p>Search for NOAA alerts by area description</p>
	<form method="POST" action="/search_alerts_area">
		<label for="areaDescription">Search Alert Area</label>
		<input
			type="text"
			id="areaDescription"
			bind:value={$form.areaDescription}
			{...$constraints.areaDescription}
		/>
		{#if $errors.areaDescription}
			<p>{$errors.areaDescription}</p>
		{/if}
		<button type="submit">Search Alerts</button>
	</form>
</div>
