import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import type { NoaaSeverityData } from '$lib/types/noaa';

const matrixWhaleUrl = import.meta.env.VITE_MATRIX_WHALE_FETCH_URL;

export const load: PageServerLoad = async () => {
	const noaaSeverityData: NoaaSeverityData[] = [] as NoaaSeverityData[];
	return {
		noaaSeverityData
	};
};

export const actions = {
	search: async ({ request }) => {
		try {
			const data = await request.formData();
			const searchWord = data.get('searchWord')?.toString() || '';

			const response = await fetch(
				new URL('/api/v1/noaa_data/search_area_description', matrixWhaleUrl),
				{
					method: 'POST',
					headers: {
						'Content-Type': 'application/json',
						Accept: 'application/json'
					},
					body: JSON.stringify({
						areaDescription: searchWord
					})
				}
			);

			if (!response.ok) {
				throw new Error(`API responded with status ${response.status}`);
			}

			const noaaSeverityList: NoaaSeverityData[] = await response.json();

			return {
				noaaSeverityData: noaaSeverityList
			};
		} catch (error) {
			console.error('Server error:', error);
			return fail(500, {
				noaaSeverityData: []
			});
		}
	}
} satisfies Actions;
