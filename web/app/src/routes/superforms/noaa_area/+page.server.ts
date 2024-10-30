import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { NoaaSeverityData } from '$lib/schema/noaa_data';
import { fail } from '@sveltejs/kit';
import { message } from 'sveltekit-superforms';
import type { Actions } from './$types';

export const load = async () => {
	const form = await superValidate(valibot(NoaaSeverityData));
	return { form };
};

export const actions = {
	search_alerts_area: async ({ request }) => {
		const form = await superValidate(request, valibot(NoaaSeverityData));
		if (!form.valid) {
			return fail(400, { form });
		}

		console.log(form.data);

		return message(form, 'Form submitted successfully');
	}
} satisfies Actions;
