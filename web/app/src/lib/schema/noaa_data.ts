import * as v from 'valibot';

export const NoaaSeverityData = v.object({
	areaDescription: v.string()
});

export const NoaaSeverityDataList = v.object({
	noaaSeverityData: v.array(NoaaSeverityData)
});
