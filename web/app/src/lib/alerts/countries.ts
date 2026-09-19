import type { Alert } from './types';

export const ISO3_TO_ISO2: Record<string, string> = {
	AFG: 'AF',
	ALB: 'AL',
	DZA: 'DZ',
	AND: 'AD',
	AGO: 'AO',
	ATG: 'AG',
	ARG: 'AR',
	ARM: 'AM',
	AUS: 'AU',
	AUT: 'AT',
	AZE: 'AZ',
	BHS: 'BS',
	BHR: 'BH',
	BGD: 'BD',
	BRB: 'BB',
	BLR: 'BY',
	BEL: 'BE',
	BLZ: 'BZ',
	BEN: 'BJ',
	BTN: 'BT',
	BOL: 'BO',
	BIH: 'BA',
	BWA: 'BW',
	BRA: 'BR',
	BRN: 'BN',
	BGR: 'BG',
	BFA: 'BF',
	BDI: 'BI',
	CPV: 'CV',
	KHM: 'KH',
	CMR: 'CM',
	CAN: 'CA',
	CAF: 'CF',
	TCD: 'TD',
	CHL: 'CL',
	CHN: 'CN',
	COL: 'CO',
	COM: 'KM',
	COG: 'CG',
	COD: 'CD',
	CRI: 'CR',
	CIV: 'CI',
	HRV: 'HR',
	CUB: 'CU',
	CYP: 'CY',
	CZE: 'CZ',
	DNK: 'DK',
	DJI: 'DJ',
	DMA: 'DM',
	DOM: 'DO',
	ECU: 'EC',
	EGY: 'EG',
	SLV: 'SV',
	GNQ: 'GQ',
	ERI: 'ER',
	EST: 'EE',
	SWZ: 'SZ',
	ETH: 'ET',
	FJI: 'FJ',
	FIN: 'FI',
	FRA: 'FR',
	GAB: 'GA',
	GMB: 'GM',
	GEO: 'GE',
	DEU: 'DE',
	GHA: 'GH',
	GRC: 'GR',
	GRD: 'GD',
	GTM: 'GT',
	GIN: 'GN',
	GNB: 'GW',
	GUY: 'GY',
	HTI: 'HT',
	HND: 'HN',
	HUN: 'HU',
	ISL: 'IS',
	IND: 'IN',
	IDN: 'ID',
	IRN: 'IR',
	IRQ: 'IQ',
	IRL: 'IE',
	ISR: 'IL',
	ITA: 'IT',
	JAM: 'JM',
	JPN: 'JP',
	JOR: 'JO',
	KAZ: 'KZ',
	KEN: 'KE',
	KIR: 'KI',
	PRK: 'KP',
	KOR: 'KR',
	KWT: 'KW',
	KGZ: 'KG',
	LAO: 'LA',
	LVA: 'LV',
	LBN: 'LB',
	LSO: 'LS',
	LBR: 'LR',
	LBY: 'LY',
	LIE: 'LI',
	LTU: 'LT',
	LUX: 'LU',
	MDG: 'MG',
	MWI: 'MW',
	MYS: 'MY',
	MDV: 'MV',
	MLI: 'ML',
	MLT: 'MT',
	MHL: 'MH',
	MRT: 'MR',
	MUS: 'MU',
	MEX: 'MX',
	FSM: 'FM',
	MDA: 'MD',
	MCO: 'MC',
	MNG: 'MN',
	MNE: 'ME',
	MAR: 'MA',
	MOZ: 'MZ',
	MMR: 'MM',
	NAM: 'NA',
	NRU: 'NR',
	NPL: 'NP',
	NLD: 'NL',
	NZL: 'NZ',
	NIC: 'NI',
	NER: 'NE',
	NGA: 'NG',
	MKD: 'MK',
	NOR: 'NO',
	OMN: 'OM',
	PAK: 'PK',
	PLW: 'PW',
	PAN: 'PA',
	PNG: 'PG',
	PRY: 'PY',
	PER: 'PE',
	PHL: 'PH',
	POL: 'PL',
	PRT: 'PT',
	QAT: 'QA',
	ROU: 'RO',
	RUS: 'RU',
	RWA: 'RW',
	KNA: 'KN',
	LCA: 'LC',
	VCT: 'VC',
	WSM: 'WS',
	SMR: 'SM',
	STP: 'ST',
	SAU: 'SA',
	SEN: 'SN',
	SRB: 'RS',
	SYC: 'SC',
	SLE: 'SL',
	SGP: 'SG',
	SVK: 'SK',
	SVN: 'SI',
	SLB: 'SB',
	SOM: 'SO',
	ZAF: 'ZA',
	SSD: 'SS',
	ESP: 'ES',
	LKA: 'LK',
	SDN: 'SD',
	SUR: 'SR',
	SWE: 'SE',
	CHE: 'CH',
	SYR: 'SY',
	TWN: 'TW',
	TJK: 'TJ',
	TZA: 'TZ',
	THA: 'TH',
	TLS: 'TL',
	TGO: 'TG',
	TON: 'TO',
	TTO: 'TT',
	TUN: 'TN',
	TUR: 'TR',
	TKM: 'TM',
	TUV: 'TV',
	UGA: 'UG',
	UKR: 'UA',
	ARE: 'AE',
	GBR: 'GB',
	USA: 'US',
	URY: 'UY',
	UZB: 'UZ',
	VUT: 'VU',
	VEN: 'VE',
	VNM: 'VN',
	YEM: 'YE',
	ZMB: 'ZM',
	ZWE: 'ZW'
};

const displayNamesCache = new Map<string, Intl.DisplayNames>();

function getDisplayNames(locale: string): Intl.DisplayNames | null {
	if (typeof Intl === 'undefined' || !Intl.DisplayNames) return null;
	let dn = displayNamesCache.get(locale);
	if (!dn) {
		try {
			dn = new Intl.DisplayNames([locale], { type: 'region' });
			displayNamesCache.set(locale, dn);
		} catch {
			return null;
		}
	}
	return dn;
}

export function getCountryName(iso3: string, locale: string = 'en'): string {
	if (!iso3) return '';
	const upperIso3 = iso3.toUpperCase();
	const iso2 = ISO3_TO_ISO2[upperIso3];
	if (!iso2) return iso3;

	const dn = getDisplayNames(locale);
	if (!dn) return iso3;

	try {
		return dn.of(iso2) ?? iso3;
	} catch {
		return iso3;
	}
}

export interface CountryOption {
	iso3: string;
	name: string;
	count: number;
}

export function activeCountriesWithCounts(alerts: Alert[], locale: string = 'en'): CountryOption[] {
	const counts = new Map<string, number>();
	for (const alert of alerts) {
		if (!alert.countries) continue;
		for (const country of alert.countries) {
			if (country) {
				const upper = country.toUpperCase();
				counts.set(upper, (counts.get(upper) ?? 0) + 1);
			}
		}
	}

	return [...counts.entries()]
		.map(([iso3, count]) => ({
			iso3,
			name: getCountryName(iso3, locale),
			count
		}))
		.sort((a, b) => a.name.localeCompare(b.name));
}
