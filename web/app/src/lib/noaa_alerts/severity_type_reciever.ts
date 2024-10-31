import { browser } from '$app/environment';
import { writable } from 'svelte/store';

export const severityData = writable<string | null>(null);

const apiUrl = import.meta.env.VITE_MATRIX_WHALE_URL;

export function initSeverityTypeReceiver(): () => void {
	if (browser) {
		console.log('Initializing EventSource...');
		const url = new URL('/api/v1/noaa_data/stream', apiUrl);
		const evtSource = new EventSource(url.toString());

		evtSource.onopen = function (event) {
			console.log('Connection opened:', event);
			severityData.set('Connected to data stream');
		};

		evtSource.onmessage = function (event) {
			console.log('Received generic message:', event.data);
			severityData.set('Generic: ' + event.data);
		};

		evtSource.addEventListener('stream_severity', function (event) {
			console.log('Received stream_severity event:', event.data);
			try {
				const data = JSON.parse(event.data);
				severityData.set('Severity: ' + data.severity);
			} catch (error) {
				console.error('Error parsing event data:', error);
				severityData.set('Parse error: ' + event.data);
			}
		});

		evtSource.onerror = function (event) {
			console.error('EventSource error:', event);
			console.log('ReadyState:', evtSource.readyState);
			if (evtSource.readyState === EventSource.CLOSED) {
				console.log('Connection was closed');
				severityData.set('Error: Connection closed');
			} else if (evtSource.readyState === EventSource.CONNECTING) {
				console.log('Attempting to reconnect...');
				severityData.set('Error: Attempting to reconnect');
			} else {
				console.log('Unknown error occurred');
				severityData.set('Error: Unknown error occurred');
			}
		};

		console.log('EventSource object:', evtSource);

		return () => {
			console.log('Closing EventSource connection');
			evtSource.close();
		};
	}

	// Return a no-op function if not in browser environment
	return () => {
		console.log('No cleanup needed (not in browser environment)');
	};
}
