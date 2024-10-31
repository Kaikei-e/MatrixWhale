import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { NoaaSeverityData } from '$lib/schema/noaa_data';
import { fail } from '@sveltejs/kit';
import type { RequestEvent } from '@sveltejs/kit';
import type { Actions } from './$types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
	const noaaSeverityData = await superValidate(valibot(NoaaSeverityData));
	return { noaaSeverityData };
};

export const actions = {
	search_alerts_area: async ({ request }: RequestEvent) => {
		const data = await request.formData();
		const searchWord = data.get('areaDescription');
		if (!searchWord) {
			return fail(400, { form: null });
		}

		console.log(searchWord);

		return { success: true };
	}
} satisfies Actions;
