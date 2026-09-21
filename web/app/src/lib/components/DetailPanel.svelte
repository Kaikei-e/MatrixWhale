<script lang="ts">
	import type { Alert, AlertDetail } from '$lib/alerts/types';
	import { formatLocalDateTime } from '$lib/alerts/timeFormat';
	import { isHttpUrl } from '$lib/feeds/logic';
	import {
		fetchAlertDetail,
		getCachedAlertDetail,
		clearAlertDetailCache
	} from '$lib/alerts/detail';

	interface Props {
		alert: Alert;
		onclose: () => void;
		onacknowledge: () => void;
		showHeader?: boolean;
	}

	let { alert, onclose, onacknowledge, showHeader = true }: Props = $props();

	let loading = $state(true);
	let error = $state<string | null>(null);
	let detail = $state<AlertDetail | null>(null);
	let retryCount = $state(0);

	const id = $derived(alert.id);
	const lastSeenAt = $derived(alert.last_seen_at);

	function retry(): void {
		clearAlertDetailCache(id, lastSeenAt);
		retryCount++;
	}

	$effect(() => {
		const targetId = id;
		const targetLastSeenAt = lastSeenAt;
		void retryCount;

		const cached = getCachedAlertDetail(targetId, targetLastSeenAt);
		if (cached) {
			detail = cached;
			loading = false;
			error = null;
			return;
		}

		loading = true;
		error = null;
		detail = null;
		const controller = new AbortController();

		async function loadDetail(): Promise<void> {
			try {
				const data = await fetchAlertDetail(targetId, targetLastSeenAt);
				if (controller.signal.aborted) return;
				detail = data;
				error = null;
			} catch (err) {
				if (controller.signal.aborted) return;
				error = err instanceof Error ? err.message : 'Detail fetch failed';
			} finally {
				if (!controller.signal.aborted) {
					loading = false;
				}
			}
		}

		void loadDetail();

		return () => {
			controller.abort();
		};
	});

	const current = $derived(detail?.alert ? { ...detail.alert, ...alert } : alert);
	const description = $derived(detail?.alert?.description ?? null);
	const instruction = $derived(detail?.alert?.instruction ?? null);
	const attributionUrl = $derived.by(() => {
		if (current.web && isHttpUrl(current.web)) return current.web;
		if (current.source === 'jma') return 'https://www.jma.go.jp/jma/kishou/info/coment.html';
		return null;
	});
	const attributionText = $derived.by(() => {
		if (current.source === 'jma') {
			return (
				current.attribution || '気象庁防災情報XMLをもとにMatrixWhaleが加工。編集責任：MatrixWhale。'
			);
		}
		return current.attribution || current.source_name;
	});

	function formatTime(iso: string | null | undefined): string | null {
		if (!iso) return null;
		try {
			return formatLocalDateTime(iso);
		} catch {
			return iso;
		}
	}
</script>

<div class="border-ink-2/30 flex flex-col gap-2.5 border-b px-3 py-3 text-sm">
	{#if showHeader}
		<div class="flex items-start justify-between gap-2">
			<h2 class="text-base font-semibold">{current.headline || current.event}</h2>
			<button
				type="button"
				onclick={onclose}
				aria-label="Close details"
				class="text-ink-2 hover:text-ink"
			>
				&times;
			</button>
		</div>
	{/if}

	{#if loading}
		<p class="text-ink-2 text-xs">Loading detail…</p>
	{:else if error}
		<div class="border-ink-2/30 flex items-center justify-between gap-2 border p-2 text-xs">
			<span class="text-ink-2">{error}</span>
			<button
				type="button"
				onclick={retry}
				class="border-ink-2/30 hover:bg-shoal border px-2 py-0.5"
			>
				Retry
			</button>
		</div>
	{/if}

	{#if showHeader && current.headline}
		<p class="text-ink text-sm font-semibold">{current.headline}</p>
	{/if}

	<p class="text-ink text-xs font-medium">{current.event}</p>

	<p class="text-ink-2 tabular text-xs">
		{current.severity} · {current.urgency} · {current.certainty}
	</p>

	<p class="text-ink-2 text-xs">{current.area_desc}</p>

	<div class="tabular text-ink-2 flex flex-col gap-0.5 text-xs">
		{#if current.onset}
			<span>Onset: <time datetime={current.onset}>{formatTime(current.onset)}</time></span>
		{/if}
		{#if current.effective}
			<span
				>Effective: <time datetime={current.effective}>{formatTime(current.effective)}</time></span
			>
		{/if}
		{#if current.expires}
			<span>Expires: <time datetime={current.expires}>{formatTime(current.expires)}</time></span>
		{/if}
		{#if current.ends}
			<span>Ends: <time datetime={current.ends}>{formatTime(current.ends)}</time></span>
		{/if}
	</div>

	{#if current.ended_at || current.end_reason || current.superseded_by}
		<div data-testid="alert-state-line" class="bg-shoal text-ink-2 rounded px-2 py-1 text-xs">
			{#if current.end_reason === 'superseded' || current.superseded_by}
				<span>Superseded{current.superseded_by ? ` by ${current.superseded_by}` : ''}</span>
			{:else if current.end_reason === 'cancelled'}
				<span>Cancelled</span>
			{:else if current.end_reason === 'expired'}
				<span>Expired</span>
			{:else}
				<span>Ended ({current.end_reason ?? 'ended'})</span>
			{/if}
			{#if current.ended_at}
				<span class="tabular"> · {formatTime(current.ended_at)}</span>
			{/if}
		</div>
	{/if}

	{#if description}
		<div class="mt-1 flex flex-col gap-1">
			<span class="text-ink-2 text-xs font-semibold">Description</span>
			<p class="text-ink text-xs whitespace-pre-wrap">{description}</p>
		</div>
	{/if}

	{#if instruction}
		<div class="mt-1 flex flex-col gap-1">
			<span class="text-ink-2 text-xs font-semibold">Instruction</span>
			<p class="text-ink text-xs whitespace-pre-wrap">{instruction}</p>
		</div>
	{/if}

	{#if current.language}
		<p class="text-ink-2 text-xs">Language: {current.language}</p>
	{/if}

	<div class="border-ink-2/30 mt-1 flex flex-col gap-1 border-t pt-2 text-xs">
		{#if attributionUrl}
			<a
				href={attributionUrl}
				target="_blank"
				rel="external noopener noreferrer"
				class="text-ink-2 hover:text-ink hover:underline"
				data-testid="alert-detail-attribution"
			>
				{attributionText}
			</a>
		{:else}
			<span class="text-ink-2" data-testid="alert-detail-attribution">{attributionText}</span>
		{/if}
	</div>

	<div class="flex items-center gap-2 pt-1">
		{#if detail?.cap_url && isHttpUrl(detail.cap_url)}
			<a
				href={detail.cap_url}
				target="_blank"
				rel="external noopener noreferrer"
				class="border-ink-2/30 hover:bg-shoal border px-2 py-1 text-xs"
			>
				CAP XML
			</a>
		{/if}
		<button
			type="button"
			onclick={onacknowledge}
			class="border-ink-2/30 hover:bg-shoal border px-2 py-1 text-xs"
		>
			Acknowledge
		</button>
	</div>
</div>
