import * as v from 'valibot';

export const NoaaSeverityData = v.object({
	severity: v.string(),
	areaDescription: v.string()
});
