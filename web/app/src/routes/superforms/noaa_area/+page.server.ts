import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { NoaaSeverityData, NoaaSeverityDataList } from '$lib/schema/noaa_data';
import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';

const matrixWhaleUrl = import.meta.env.VITE_MATRIX_WHALE_URL;

export const load: PageServerLoad = async () => {
    const form = await superValidate(valibot(NoaaSeverityDataList));
    return {
        form,
        noaaSeverityData: { areaDescription: '' }
    };
};

export const actions = {
	search_alerts_area: async ({ request }) => {
		const form = await superValidate(request, valibot(NoaaSeverityData));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const formData = new URLSearchParams();
			formData.append('areaDescription', form.data.areaDescription);

			const response = await fetch(
				new URL('/api/v1/noaa_data/search_area_description', matrixWhaleUrl),
				{
					method: 'POST',
					headers: {
						'Content-Type': 'application/x-www-form-urlencoded',
						Accept: 'application/json',
						'x-sveltekit-action': 'true'

					},
					body: formData
				}
			);

			if (!response.ok) {
				return fail(response.status, {
					form,
					noaaSeverityData: { areaDescription: '' }
				});
			}

			const result = await response.json();
			return {
				form,
				noaaSeverityData: result
			};
		} catch (error) {
			console.error(error);
			return fail(500, {
				form,
				noaaSeverityData: { areaDescription: '' }
			});
		}
	}
} satisfies Actions;
