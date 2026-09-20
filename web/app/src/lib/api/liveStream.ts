export const DEFAULT_SHARED_STREAM_URL = '/api/v1/stream?geometry=polyline';

export type StreamChannelName = 'alerts' | 'earthquakes' | 'hazards';

export interface LiveStreamSubscription {
	addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void;
	removeEventListener(type: string, listener: (event: MessageEvent<string>) => void): void;
	onopen: ((event: Event) => void) | null;
	onerror: ((event: Event) => void) | null;
	onreconnect?: (() => void) | null;
	close(): void;
	restart(): void;
	readonly url: string;
}

export function isSharedStreamUrl(url: string | undefined): boolean {
	return url === undefined || url === DEFAULT_SHARED_STREAM_URL;
}

class SharedChannelSubscription implements LiveStreamSubscription {
	#manager: SharedLiveStreamManager;
	#channelName: StreamChannelName;
	#listeners = new Map<string, Set<(event: MessageEvent<string>) => void>>();
	#closed = false;
	onopen: ((event: Event) => void) | null = null;
	onerror: ((event: Event) => void) | null = null;
	onreconnect?: (() => void) | null = null;
	readonly url: string;

	constructor(manager: SharedLiveStreamManager, channelName: StreamChannelName, url: string) {
		this.#manager = manager;
		this.#channelName = channelName;
		this.url = url;
	}

	get isClosed(): boolean {
		return this.#closed;
	}

	addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		if (this.#closed) return;
		let set = this.#listeners.get(type);
		if (!set) {
			set = new Set();
			this.#listeners.set(type, set);
		}
		set.add(listener);
	}

	removeEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		const set = this.#listeners.get(type);
		if (set) {
			set.delete(listener);
			if (set.size === 0) {
				this.#listeners.delete(type);
			}
		}
	}

	notifyOpen(event: Event): void {
		if (this.#closed) return;
		this.onopen?.(event);
	}

	notifyError(event: Event): void {
		if (this.#closed) return;
		this.onerror?.(event);
	}

	notifyReconnect(): void {
		if (this.#closed) return;
		this.onreconnect?.();
		const set = this.#listeners.get('reconnect');
		if (set) {
			const evt = new MessageEvent('reconnect', { data: '' });
			for (const listener of [...set]) {
				listener(evt);
			}
		}
	}

	handleIncomingEvent(incomingType: string, event: MessageEvent<string>): void {
		if (this.#closed) return;

		const targetTypes = this.#matchEventTypes(incomingType);
		if (targetTypes.length === 0) return;

		for (const targetType of targetTypes) {
			const set = this.#listeners.get(targetType);
			if (set && set.size > 0) {
				const forwarded = new MessageEvent(targetType, {
					data: event.data,
					lastEventId: event.lastEventId,
					origin: event.origin
				});
				for (const listener of [...set]) {
					listener(forwarded);
				}
			}
		}
	}

	#matchEventTypes(incomingType: string): string[] {
		if (this.#channelName === 'alerts') {
			if (incomingType === 'alerts.new') {
				return ['alert.new', 'alerts.new'];
			}
			if (incomingType === 'alerts.update') {
				return ['alert.update', 'alerts.update'];
			}
			if (incomingType === 'alerts.ended') {
				return ['alert.ended', 'alerts.ended'];
			}
			if (incomingType === 'alerts.heartbeat') {
				return ['heartbeat', 'alerts.heartbeat'];
			}
			if (incomingType === 'alerts.resync') {
				return ['resync', 'alerts.resync'];
			}
			return [];
		}

		if (this.#channelName === 'earthquakes') {
			if (incomingType === 'earthquakes.new') {
				return ['new', 'earthquakes.new'];
			}
			if (incomingType === 'earthquakes.update') {
				return ['update', 'earthquakes.update'];
			}
			if (incomingType === 'earthquakes.heartbeat') {
				return ['heartbeat', 'earthquakes.heartbeat'];
			}
			if (incomingType === 'earthquakes.resync') {
				return ['resync', 'earthquakes.resync'];
			}
			return [];
		}

		if (this.#channelName === 'hazards') {
			if (incomingType === 'hazards.new') {
				return ['new', 'hazards.new'];
			}
			if (incomingType === 'hazards.update') {
				return ['update', 'hazards.update'];
			}
			if (incomingType === 'hazards.heartbeat') {
				return ['heartbeat', 'hazards.heartbeat'];
			}
			if (incomingType === 'hazards.resync') {
				return ['resync', 'hazards.resync'];
			}
			return [];
		}

		return [];
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#listeners.clear();
		this.onopen = null;
		this.onerror = null;
		this.onreconnect = null;
		this.#manager.unsubscribe(this);
	}

	restart(): void {
		if (this.#closed) return;
		this.#manager.restart();
	}
}

class DedicatedChannelSubscription implements LiveStreamSubscription {
	#url: string;
	#es: EventSource | null = null;
	#listeners = new Map<string, Set<(event: MessageEvent<string>) => void>>();
	#esDispatchers = new Map<string, (event: MessageEvent<string>) => void>();
	#closed = false;
	onopen: ((event: Event) => void) | null = null;
	onerror: ((event: Event) => void) | null = null;
	onreconnect?: (() => void) | null = null;

	constructor(url: string) {
		this.#url = url;
		this.#open();
	}

	get url(): string {
		return this.#url;
	}

	#open(): void {
		const es = new EventSource(this.#url);
		this.#es = es;
		this.#esDispatchers.clear();

		es.onopen = (event) => {
			if (this.#es !== es || this.#closed) return;
			this.onopen?.(event);
		};

		es.onerror = (event) => {
			if (this.#es !== es || this.#closed) return;
			this.onerror?.(event);
		};

		for (const type of this.#listeners.keys()) {
			this.#attachEsDispatcher(es, type);
		}
	}

	#attachEsDispatcher(es: EventSource, type: string): void {
		if (this.#esDispatchers.has(type)) return;
		const dispatcher = (event: MessageEvent<string>) => {
			if (this.#es !== es || this.#closed) return;
			const current = this.#listeners.get(type);
			if (current) {
				for (const listener of [...current]) {
					listener(event);
				}
			}
		};
		this.#esDispatchers.set(type, dispatcher);
		es.addEventListener(type, dispatcher);
	}

	addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		if (this.#closed) return;
		let set = this.#listeners.get(type);
		if (!set) {
			set = new Set();
			this.#listeners.set(type, set);
		}
		set.add(listener);
		if (this.#es) {
			this.#attachEsDispatcher(this.#es, type);
		}
	}

	removeEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
		const set = this.#listeners.get(type);
		if (set) {
			set.delete(listener);
			if (set.size === 0) {
				this.#listeners.delete(type);
				const dispatcher = this.#esDispatchers.get(type);
				if (dispatcher && this.#es) {
					this.#es.removeEventListener(type, dispatcher);
					this.#esDispatchers.delete(type);
				}
			}
		}
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#listeners.clear();
		this.#esDispatchers.clear();
		this.onopen = null;
		this.onerror = null;
		this.onreconnect = null;
		this.#es?.close();
		this.#es = null;
	}

	restart(): void {
		if (this.#closed) return;
		this.#es?.close();
		this.#es = null;
		this.#esDispatchers.clear();
		this.onreconnect?.();
		this.#open();
	}
}

export class SharedLiveStreamManager {
	#url = DEFAULT_SHARED_STREAM_URL;
	#es: EventSource | null = null;
	#channels = new Set<SharedChannelSubscription>();
	#isOpen = false;
	#isConnecting = false;
	#connectingStartedAt = 0;

	get subscriberCount(): number {
		return this.#channels.size;
	}

	get isOpen(): boolean {
		return this.#isOpen;
	}

	get isConnecting(): boolean {
		return this.#isConnecting;
	}

	get eventSource(): EventSource | null {
		return this.#es;
	}

	subscribe(channelName: StreamChannelName): LiveStreamSubscription {
		const channel = new SharedChannelSubscription(this, channelName, this.#url);
		this.#channels.add(channel);

		if (!this.#es) {
			this.#connect();
		} else if (this.#isOpen) {
			queueMicrotask(() => {
				if (!channel.isClosed && this.#isOpen) {
					channel.notifyOpen(new Event('open'));
				}
			});
		}

		return channel;
	}

	unsubscribe(channel: SharedChannelSubscription): void {
		if (!this.#channels.has(channel)) return;
		this.#channels.delete(channel);
		if (this.#channels.size === 0) {
			this.#disconnect();
		}
	}

	restart(): void {
		if (this.#channels.size === 0) return;

		const now = Date.now();
		if (this.#isConnecting && now - this.#connectingStartedAt < 10000) {
			// Coalesce per transport generation while new socket is connecting.
			// Notify all active logical subscribers so watchdogs reset.
			for (const channel of [...this.#channels]) {
				channel.notifyReconnect();
			}
			return;
		}

		this.#disconnectUnderlying();
		if (this.#channels.size > 0) {
			this.#connect();
		}
		for (const channel of [...this.#channels]) {
			channel.notifyReconnect();
		}
	}

	reset(): void {
		for (const channel of this.#channels) {
			channel.close();
		}
		this.#channels.clear();
		this.#disconnectUnderlying();
	}

	#connect(): void {
		if (this.#es) return;
		this.#isOpen = false;
		this.#isConnecting = true;
		this.#connectingStartedAt = Date.now();
		const es = new EventSource(this.#url);
		this.#es = es;

		es.onopen = (event) => {
			if (this.#es !== es) return;
			this.#isOpen = true;
			this.#isConnecting = false;
			for (const channel of [...this.#channels]) {
				if (!channel.isClosed) {
					channel.notifyOpen(event);
				}
			}
		};

		es.onerror = (event) => {
			if (this.#es !== es) return;
			this.#isOpen = false;
			this.#isConnecting = false;
			for (const channel of [...this.#channels]) {
				if (!channel.isClosed) {
					channel.notifyError(event);
				}
			}
		};

		const allEventTypes = [
			'alerts.new',
			'alerts.update',
			'alerts.ended',
			'alerts.heartbeat',
			'alerts.resync',
			'earthquakes.new',
			'earthquakes.update',
			'earthquakes.heartbeat',
			'earthquakes.resync',
			'hazards.new',
			'hazards.update',
			'hazards.heartbeat',
			'hazards.resync'
		];

		for (const type of allEventTypes) {
			es.addEventListener(type, (event: MessageEvent<string>) => {
				if (this.#es !== es) return;
				this.#dispatchEvent(type, event);
			});
		}
	}

	#dispatchEvent(type: string, event: MessageEvent<string>): void {
		for (const channel of [...this.#channels]) {
			if (!channel.isClosed) {
				channel.handleIncomingEvent(type, event);
			}
		}
	}

	#disconnectUnderlying(): void {
		this.#isOpen = false;
		this.#isConnecting = false;
		if (this.#es) {
			this.#es.close();
			this.#es = null;
		}
	}

	#disconnect(): void {
		this.#disconnectUnderlying();
	}
}

const sharedManager = new SharedLiveStreamManager();

export function getSharedLiveStream(): SharedLiveStreamManager {
	return sharedManager;
}

export function resetSharedLiveStream(): void {
	sharedManager.reset();
}

export function openStreamChannel(
	channel: StreamChannelName,
	streamUrl?: string
): LiveStreamSubscription {
	if (isSharedStreamUrl(streamUrl)) {
		return sharedManager.subscribe(channel);
	}
	return new DedicatedChannelSubscription(streamUrl!);
}
