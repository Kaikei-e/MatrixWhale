import { SvelteMap, SvelteSet } from 'svelte/reactivity';
import { SEVERITIES, type Alert, type BlinkMode, type BlinkState, type Severity } from './types';
import { sortByNwsPriority } from './priority';
import { loadAcknowledged, saveAcknowledged, loadFlag, saveFlag } from './storage';

const ARRIVAL_MS = 5000;
const UPDATE_MS = 1000;
const ENDED_MS = 1000;
const HEARTBEAT_TIMEOUT_MS = 60000;

export function nextBlinkAfterArrival(severity: Severity, acknowledged: boolean): BlinkMode {
	if (acknowledged) return 'static';
	return severity === 'Extreme' || severity === 'Severe' ? 'persistent' : 'static';
}

export class AlertStore {
	activeAlerts = new SvelteMap<string, Alert>();
	blink = new SvelteMap<string, BlinkState>();
	acknowledged = new SvelteSet<string>(loadAcknowledged());
	reducedMotion = $state(false);
	connected: 'connecting' | 'open' | 'closed' = $state('closed');
	snapshotError: string | null = $state(null);

	#stopAll = $state(loadFlag('alerts.stopAll', false));
	#useNwsColors = $state(loadFlag('alerts.useNwsColors', false));

	#es: EventSource | undefined;
	#snapshotUrl: string | undefined;
	#alertTimers = new SvelteMap<string, ReturnType<typeof setTimeout>>();
	#watchdog: ReturnType<typeof setTimeout> | undefined;

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

	countsBySeverity = $derived.by(() => {
		const counts = { Extreme: 0, Severe: 0, Moderate: 0, Minor: 0, Unknown: 0 } as Record<
			Severity,
			number
		>;
		for (const alert of this.activeAlerts.values()) counts[alert.severity]++;
		return counts;
	});

	zoneSeverity = $derived.by(() => {
		const result = new SvelteMap<string, Severity>();
		for (const alert of this.activeAlerts.values()) {
			for (const ugc of alert.ugc) {
				const current = result.get(ugc);
				if (!current || SEVERITIES.indexOf(alert.severity) < SEVERITIES.indexOf(current)) {
					result.set(ugc, alert.severity);
				}
			}
		}
		return result;
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

	async connect(snapshotUrl: string, streamUrl: string): Promise<void> {
		if (this.#es) return;
		this.#snapshotUrl = snapshotUrl;
		this.connected = 'connecting';
		this.#openStream(streamUrl);
		await this.#loadSnapshot(snapshotUrl);
	}

	disconnect(): void {
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
		this.#clearAlertTimer(id);
		if (this.activeAlerts.has(id)) this.blink.set(id, { mode: 'static', until: null });
	}

	retrySnapshot(): void {
		if (this.#snapshotUrl) void this.#loadSnapshot(this.#snapshotUrl);
	}

	async #loadSnapshot(url: string): Promise<void> {
		try {
			const response = await fetch(url);
			if (!response.ok) throw new Error(`snapshot request failed with status ${response.status}`);
			const alerts = (await response.json()) as Alert[];

			this.activeAlerts.clear();
			this.blink.clear();
			for (const alert of alerts) {
				this.activeAlerts.set(alert.id, alert);
				this.blink.set(alert.id, {
					mode: nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id)),
					until: null
				});
			}
			this.snapshotError = null;
		} catch (error) {
			this.snapshotError = error instanceof Error ? error.message : 'snapshot request failed';
		}
	}

	#openStream(url: string): void {
		const es = new EventSource(url);
		es.addEventListener('alert.new', this.#handleNew);
		es.addEventListener('alert.update', this.#handleUpdate);
		es.addEventListener('alert.ended', this.#handleEnded);
		es.addEventListener('heartbeat', this.#handleHeartbeat);
		es.onerror = this.#handleError;
		this.#es = es;
	}

	#clearAlertTimer(id: string): void {
		const timer = this.#alertTimers.get(id);
		if (timer) clearTimeout(timer);
		this.#alertTimers.delete(id);
	}

	#handleNew = (event: MessageEvent<string>): void => {
		const alert = JSON.parse(event.data) as Alert;
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'arrival', until: performance.now() + ARRIVAL_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			const mode = nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id));
			this.blink.set(alert.id, { mode, until: null });
			this.#alertTimers.delete(alert.id);
		}, ARRIVAL_MS);
		this.#alertTimers.set(alert.id, timer);
	};

	#handleUpdate = (event: MessageEvent<string>): void => {
		const alert = JSON.parse(event.data) as Alert;
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'update', until: performance.now() + UPDATE_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			const mode = nextBlinkAfterArrival(alert.severity, this.acknowledged.has(alert.id));
			this.blink.set(alert.id, { mode, until: null });
			this.#alertTimers.delete(alert.id);
		}, UPDATE_MS);
		this.#alertTimers.set(alert.id, timer);
	};

	#handleEnded = (event: MessageEvent<string>): void => {
		const alert = JSON.parse(event.data) as Alert;
		this.activeAlerts.set(alert.id, alert);
		this.blink.set(alert.id, { mode: 'fading', until: performance.now() + ENDED_MS });
		this.#clearAlertTimer(alert.id);
		const timer = setTimeout(() => {
			this.activeAlerts.delete(alert.id);
			this.blink.delete(alert.id);
			this.#alertTimers.delete(alert.id);
		}, ENDED_MS);
		this.#alertTimers.set(alert.id, timer);
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
