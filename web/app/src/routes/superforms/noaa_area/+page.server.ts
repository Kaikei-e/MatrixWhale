import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { NoaaSeverityData } from '$lib/schema/noaa_data';
import { fail } from '@sveltejs/kit';
import type { RequestEvent } from '@sveltejs/kit';
import type { Actions } from './$types';
import type { PageServerLoad } from './$types';

const matrixWhaleUrl = import.meta.env.VITE_MATRIX_WHALE_URL;

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

		const body = JSON.stringify({ areaDescription: searchWord });

		const url = new URL('/api/v1/noaa_data/search_area_description', matrixWhaleUrl);
		const response = await fetch(url.toString(), {
			method: 'POST',
			body: body
		});

		const json = await response.json();
		if (!response.ok) {
			return fail(500, { form: null });
		}

		console.log(json);

		return json;
	}
} satisfies Actions;
