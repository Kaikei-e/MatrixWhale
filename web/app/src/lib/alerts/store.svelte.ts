import { SvelteMap, SvelteSet } from 'svelte/reactivity';
import {
	type Alert,
	type BlinkMode,
	type BlinkState,
	type RawAlertEvent,
	type Severity
} from './types';
import { sortByNwsPriority } from './priority';
import { computeZoneSeverity } from './geocodes';
import { activeCountriesWithCounts, type CountryOption } from './countries';
import { filterAlerts } from './filter';
import { loadAcknowledged, saveAcknowledged, loadFlag, saveFlag } from './storage';

const ARRIVAL_MS = 5000;
const UPDATE_MS = 1000;
const ENDED_MS = 1000;
const HEARTBEAT_TIMEOUT_MS = 60000;
const SNAPSHOT_TIMEOUT_MS = 10000;

export function nextBlinkAfterArrival(severity: Severity, acknowledged: boolean): BlinkMode {
	if (acknowledged) return 'static';
	return severity === 'Extreme' || severity === 'Severe' ? 'persistent' : 'static';
}

function parseAlertRecord(data: unknown): Alert | null {
	if (!data || typeof data !== 'object') return null;
	if ('id' in data) {
		return data as Alert;
	}
	return null;
}

interface BufferedEvent {
	type: 'new' | 'update' | 'ended';
	alert: Alert;
}

export class AlertStore {
	activeAlerts = new SvelteMap<string, Alert>();
	blink = new SvelteMap<string, BlinkState>();
	acknowledged = new SvelteSet<string>(loadAcknowledged());
	reducedMotion = $state(false);
	connected: 'connecting' | 'open' | 'closed' = $state('closed');
	snapshotError: string | null = $state(null);

	severityFilter = new SvelteSet<Severity>(['Extreme', 'Severe', 'Moderate']);
	countryFilter = $state<string>('all');

	#stopAll = $state(loadFlag('alerts.stopAll', false));
	#useNwsColors = $state(loadFlag('alerts.useNwsColors', false));

	#es: EventSource | undefined;
	#snapshotUrl: string | undefined;
	#alertTimers = new SvelteMap<string, ReturnType<typeof setTimeout>>();
	#watchdog: ReturnType<typeof setTimeout> | undefined;
	#rawListeners = new SvelteSet<(event: RawAlertEvent) => void>();
	#streamBuffer: Array<BufferedEvent> | null = null;
	#snapshotAbortController: AbortController | undefined;

	get stopAll(): boolean {
		return this.#stopAll;
	}

	set stopAll(value: boolean) {
		this.#stopAll = value;
		saveFlag('alerts.stopAll', value);
	}

	get useNwsColors(): boolean {
		return this.#useNwsColors;
	}

	set useNwsColors(value: boolean) {
		this.#useNwsColors = value;
		saveFlag('alerts.useNwsColors', value);
	}

	toggleSeverity(severity: Severity): void {
		if (this.severityFilter.has(severity)) {
			this.severityFilter.delete(severity);
		} else {
			this.severityFilter.add(severity);
		}
		this.#checkCountryReset();
	}

	#checkCountryReset(): void {
		if (
			this.countryFilter !== 'all' &&
			!this.activeCountries.some((c) => c.iso3 === this.countryFilter)
		) {
			this.countryFilter = 'all';
		}
	}

	countsBySeverity = $derived.by(() => {
		const counts = { Extreme: 0, Severe: 0, Moderate: 0, Minor: 0, Unknown: 0 } as Record<
			Severity,
			number
		>;
		for (const alert of this.activeAlerts.values()) counts[alert.severity]++;
		return counts;
	});

	zoneSeverity = $derived.by(() => computeZoneSeverity(this.filtered));

	activeCountries = $derived.by((): CountryOption[] => {
		const matching = [...this.activeAlerts.values()].filter((alert) =>
			this.severityFilter.has(alert.severity)
		);
		return activeCountriesWithCounts(matching);
	});

	hasAnyBlinking = $derived.by(() => {
		if (this.stopAll || this.reducedMotion) return false;
		for (const state of this.blink.values()) {
			if (state.mode === 'arrival' || state.mode === 'persistent' || state.mode === 'update') {
				return true;
			}
		}
		return false;
	});

	sorted = $derived.by(() => sortByNwsPriority([...this.activeAlerts.values()]));

	filtered = $derived.by(() => filterAlerts(this.sorted, this.severityFilter, this.countryFilter));

	async connect(snapshotUrl: string, streamUrl: string): Promise<void> {
		if (this.#es) return;
		this.#snapshotUrl = snapshotUrl;
		this.connected = 'connecting';
		this.#streamBuffer = [];
		this.#openStream(streamUrl);
		await this.#loadSnapshot(snapshotUrl);
	}

	disconnect(): void {
		if (this.#snapshotAbortController) {
			this.#snapshotAbortController.abort();
			this.#snapshotAbortController = undefined;
		}
		this.#streamBuffer = null;
		this.#es?.close();
		this.#es = undefined;
		if (this.#watchdog) clearTimeout(this.#watchdog);
		this.#watchdog = undefined;
		for (const timer of this.#alertTimers.values()) clearTimeout(timer);
		this.#alertTimers.clear();
		this.connected = 'closed';
	}

	acknowledge(id: string): void {
		this.acknowledged.add(id);
		saveAcknowledged(new SvelteSet(this.acknowledged));
		if (this.blink.get(id)?.mode === 'fading') return;
		this.#clearAlertTimer(id);
		if (this.activeAlerts.has(id)) this.blink.set(id, { mode: 'static', until: null });
	}

	retrySnapshot(): void {
		if (this.#snapshotUrl) void this.#loadSnapshot(this.#snapshotUrl);
	}

	/** Raw SSE payloads for the unified timeline, delivered before this store's own filtering. */
	subscribeRaw(listener: (event: RawAlertEvent) => void): () => void {
		this.#rawListeners.add(listener);
		return () => this.#rawListeners.delete(listener);
	}

	#emitRaw(event: RawAlertEvent): void {
		for (const listener of this.#rawListeners) listener(event);
	}

	async #loadSnapshot(url: string): Promise<void> {
		if (this.#snapshotAbortController) {
			this.#snapshotAbortController.abort();
		}
		const ac = new AbortController();
		this.#snapshotAbortController = ac;
		const buffer = this.#streamBuffer ?? [];
		this.#streamBuffer = buffer;

		try {
			const timeoutSignal = AbortSignal.timeout(SNAPSHOT_TIMEOUT_MS);
			const signal = AbortSignal.any([ac.signal, timeoutSignal]);
			const response = await fetch(url, { signal });
			if (!response.ok) throw new Error(`snapshot request failed with status ${response.status}`);
			const alerts = (await response.json()) as Alert[];
			if (ac.signal.aborted) return;

			this.activeAlerts.clear();
			this.blink.clear();
			for (const timer of this.#alertTimers.values()) clearTimeout(timer);
			this.#alertTimers.clear();
			for (const alert of alerts) {
				this.activeAlerts.set(alert.id, alert);
				this.blink.set(alert.id, {
					mode: nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id)),
					until: null
				});
			}
			this.snapshotError = null;
			this.#checkCountryReset();
		} catch (error) {
			if (ac.signal.aborted) return;
			this.snapshotError = error instanceof Error ? error.message : 'snapshot request failed';
		} finally {
			if (this.#snapshotAbortController === ac) {
				this.#snapshotAbortController = undefined;
				this.#streamBuffer = null;
				for (const item of buffer) {
					const existing = this.activeAlerts.get(item.alert.id);
					if (existing && Date.parse(item.alert.last_seen_at) < Date.parse(existing.last_seen_at)) {
						continue;
					}
					if (item.type === 'new') {
						this.#applyNew(item.alert);
					} else if (item.type === 'update') {
						this.#applyUpdate(item.alert);
					} else if (item.type === 'ended') {
						this.#applyEnded(item.alert);
					}
				}
			}
		}
	}

	#openStream(url: string): void {
		const es = new EventSource(url);
		es.addEventListener('alert.new', this.#handleNew);
		es.addEventListener('alert.update', this.#handleUpdate);
		es.addEventListener('alert.ended', this.#handleEnded);
		es.addEventListener('resync', this.#handleResync);
		es.addEventListener('heartbeat', this.#handleHeartbeat);
		es.onerror = this.#handleError;
		this.#es = es;
	}

	#handleResync = (): void => {
		this.#emitRaw({ type: 'resync' });
		if (this.#snapshotUrl) void this.#loadSnapshot(this.#snapshotUrl);
	};

	#clearAlertTimer(id: string): void {
		const timer = this.#alertTimers.get(id);
		if (timer) clearTimeout(timer);
		this.#alertTimers.delete(id);
	}

	#applyNew(alert: Alert): void {
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'arrival', until: performance.now() + ARRIVAL_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			if (!this.activeAlerts.has(alert.id)) {
				this.#alertTimers.delete(alert.id);
				return;
			}
			const mode = nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id));
			this.blink.set(alert.id, { mode, until: null });
			this.#alertTimers.delete(alert.id);
		}, ARRIVAL_MS);
		this.#alertTimers.set(alert.id, timer);
		this.#checkCountryReset();
	}

	#applyUpdate(alert: Alert): void {
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'update', until: performance.now() + UPDATE_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			if (!this.activeAlerts.has(alert.id)) {
				this.#alertTimers.delete(alert.id);
				return;
			}
			const mode = nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id));
			this.blink.set(alert.id, { mode, until: null });
			this.#alertTimers.delete(alert.id);
		}, UPDATE_MS);
		this.#alertTimers.set(alert.id, timer);
		this.#checkCountryReset();
	}

	#applyEnded(alert: Alert): void {
		if (!this.activeAlerts.has(alert.id)) return;
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'fading', until: performance.now() + ENDED_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			if (!this.activeAlerts.has(alert.id)) {
				this.#alertTimers.delete(alert.id);
				return;
			}
			this.activeAlerts.delete(alert.id);
			this.blink.delete(alert.id);
			this.#alertTimers.delete(alert.id);
			this.#checkCountryReset();
		}, ENDED_MS);
		this.#alertTimers.set(alert.id, timer);
	}

	#handleNew = (event: MessageEvent<string>): void => {
		let raw: unknown;
		try {
			raw = JSON.parse(event.data);
		} catch {
			return;
		}
		const alert = parseAlertRecord(raw);
		if (!alert) return;
		this.#emitRaw({ type: 'new', record: alert });
		if (this.#streamBuffer) {
			this.#streamBuffer.push({ type: 'new', alert });
		} else {
			this.#applyNew(alert);
		}
	};

	#handleUpdate = (event: MessageEvent<string>): void => {
		let raw: unknown;
		try {
			raw = JSON.parse(event.data);
		} catch {
			return;
		}
		const alert = parseAlertRecord(raw);
		if (!alert) return;
		this.#emitRaw({ type: 'update', record: alert });
		if (this.#streamBuffer) {
			this.#streamBuffer.push({ type: 'update', alert });
		} else {
			this.#applyUpdate(alert);
		}
	};

	#handleEnded = (event: MessageEvent<string>): void => {
		let raw: unknown;
		try {
			raw = JSON.parse(event.data);
		} catch {
			return;
		}
		const alert = parseAlertRecord(raw);
		if (!alert) return;
		if (this.#streamBuffer) {
			this.#emitRaw({ type: 'ended', record: alert });
			this.#streamBuffer.push({ type: 'ended', alert });
		} else {
			if (!this.activeAlerts.has(alert.id)) return;
			this.#emitRaw({ type: 'ended', record: alert });
			this.#applyEnded(alert);
		}
	};

	#handleHeartbeat = (): void => {
		this.connected = 'open';
		if (this.#watchdog) clearTimeout(this.#watchdog);
		this.#watchdog = setTimeout(() => {
			this.connected = 'closed';
		}, HEARTBEAT_TIMEOUT_MS);
	};

	#handleError = (): void => {
		this.connected = 'closed';
	};
}

export const alertStore = new AlertStore();
