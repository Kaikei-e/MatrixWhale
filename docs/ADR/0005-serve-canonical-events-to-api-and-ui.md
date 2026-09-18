---
title: 公開 API と UI の地震の単位を canonical event にする
status: accepted
date: 2026-09-18
depends-on: ["0003", "0004"]
---

# 0005: 公開 API と UI の地震の単位を canonical event にする

## コンテキスト

[[0003]] で USGS と EMSC の同一地震を `sea.event` に統合したが、API と UI が引き続きソース行 (`sea.earthquake`) を単位にしていれば、`/globe` には同じ地震が 2 点描かれる。Web クライアントは `source:source_id` をキーに `Map` を組み、`updated_at_ms` を revision ガードにし、出典を "Credit: U.S. Geological Survey" とハードコードしていた。

選択肢は 3 つあった。

1. API は canonical を返す新エンドポイントを足すだけにし、UI は現状維持 (重複表示は残る)。
2. UI は USGS のみ表示し、EMSC は API でだけ見える (重複は避けられるが EMSC が地図に出ない)。
3. `/api/v1/earthquakes/recent` と SSE の payload を canonical event に変え、UI も切り替える。

ユーザは 3 を選んだ。全球化の目的 (idea2 §6「/globe との接続」) からすれば、EMSC が地図に出ないのでは意味がなく、重複表示も許容できない。

制約として、コア側 (Gleam) と Web 側 (SvelteKit) を別のエージェントが並列に実装する計画だったため、API の契約を実装前に文書として固定し、Web はモックとフィクスチャに対して、コアは統合テストに対して、それぞれ独立に検証できるようにする必要があった。

## 決定

### API 契約

- `GET /api/v1/earthquakes/recent`: クエリパラメータ (`hours=1..168`、`minmag=<number>|all`、`type=earthquake|all`)、ETag と `Cache-Control: no-cache` はそのまま。応答は `{"earthquakes": [<Event>, ...]}` で、要素が canonical event になる。絞り込みは `sea.event` の投影列で行う。
- `GET /api/v1/earthquakes/stream` (SSE): `new` (event の新規作成) と `update` (メンバー追加・改訂・status 変化による投影の変化) が `<Event>` に `is_backfill` を添えて流れる。`heartbeat` と `resync`、SSE の `id` は変更なし。
- `<Event>` の形 (抜粋):

  ```json
  {
    "id": 4821,
    "kind": "earthquake",
    "magnitude": 5.3, "magnitude_type": "mww",
    "occurred_at": "...", "occurred_at_ms": 1789999026000,
    "updated_at": "...", "updated_at_ms": 1790000906512,
    "place": "...", "title": "...", "status": "reviewed", "event_type": "earthquake",
    "tsunami": 0, "significance": 431, "alert": null, "mmi": null, "cdi": null,
    "felt": null, "nst": null, "dmin": null, "rms": null, "gap": null,
    "net": "us", "code": "7000abcd", "url": "...", "detail": null,
    "longitude": -70.43, "latitude": -32.69, "depth_km": 14.8,
    "preferred_source": "usgs",
    "sources": ["usgs", "emsc"],
    "members": [
      {"source": "usgs", "source_id": "us7000abcd", "magnitude": 5.3, "magnitude_type": "mww",
       "occurred_at_ms": 1789999026000, "updated_at_ms": 1790000906512,
       "latitude": -32.69, "longitude": -70.43, "depth_km": 14.8, "place": "...",
       "status": "reviewed", "url": "...", "matched_by": "origin", "misfit": null},
      {"source": "emsc", "source_id": "20260917_0000234", "matched_by": "misfit", "misfit": 0.31, "...": "..."}
    ],
    "first_seen_at": "...", "last_seen_at": "..."
  }
  ```

  投影されるスカラー値は優先メンバーの値で、優先ソースに無い項目 (EMSC なら `tsunami`、`significance`、`alert`、`mmi` など) は `null`。`updated_at_ms` はメンバーの最大値で、クライアントの revision ガードとして使い続ける。`status === "deleted"` のクライアント側除外も従来どおり。
- 削除した項目: トップレベルの `source`、`source_id`、`contributing_ids`、`license`、`attribution`、`redistributable`。出典は `GET /api/v1/sources` ([[0004]]) から取る。
- `id` は `sea.event.id` (整数) で、`source:source_id` 文字列ではない。

この契約はスクラッチパッドの `canonical_event_contract.md` として実装前に固定し、コアと Web の双方がそれに対して実装した。

### Web の変更

- `src/lib/earthquakes/types.ts`: `Earthquake` を canonical の形に置き換え (`id`、`preferred_source`、`sources`、`members`)、`EarthquakeMember` と `DataSource` を追加、`earthquakeKey` は削除 (互換 shim は置かない)。
- `store.svelte.ts`: 全ての `Map` を数値 `id` でキーにし、revision ガード・backfill のフラッシュ抑止・フィルタ・`resync`・watchdog は据え置き。`fetchSources()` で `/api/v1/sources` を一度取得し `Map<string, DataSource>` に保持する。
- `EarthquakeMarkers.svelte` / `globe/+page.svelte`: 選択とフォーカスを `id` に。`?focus=<id>` は event id を受ける。
- `EarthquakePanel.svelte`: 優先ソースの外部リンク (ラベルは `preferred_source` から生成)、メンバー一覧 (ソース名・M と種別・`matched_by`・misfit)、選択イベントの出典リンク、および画面に載っている全ソースの出典を優先度降順で並べた常時表示フッター。
- テスト: Vitest のフィクスチャと Playwright の `mockBackend` (`/api/v1/sources` のルートを追加) を新契約に更新し、2 メンバーのイベント表示、両ソースの出典、`update` の revision ガード (`id` 単位)、`?focus=` の 4 点を追加した。

## 根拠（調査結果・出典）

- 契約を先に固定した効果: Web (Phase 5) はコア (Phase 4b) の完成を待たずにモックで検証を完了し (型チェック 0 エラー、Vitest 87 件、Playwright 8 件、build 成功)、コア完成後に統合したところ契約の食い違いは無かった。並列開発の前提が成立した実証である。
- 統合後の実測: dev volume を作り直したスタックで `/api/v1/earthquakes/recent?hours=168&minmag=all&type=all` は 4,207 event を返し、うち 448 が 2 メンバー (USGS + EMSC) だった。proxy 経由の `/globe` と API はともに 200。
- `updated_at_ms` を「メンバーの最大値」にすると、既存のクライアント側ガード (`current.updated_at_ms >= incoming.updated_at_ms` なら無視) をそのまま流用でき、どのソースが改訂されても単調に増える。
- 出典を API の各レコードから外して `/api/v1/sources` に寄せた理由は [[0004]] のとおり。CC BY 4.0 の帰属要件を満たすため、常時表示フッターを追加した。https://www.seismicportal.eu/terms.html

## 検討した代替案

- **API に `/api/v1/events` を新設し、既存の `/recent` と `/stream` は残す**: 移行期間を作れるが、リポジトリ内の唯一の消費者は Web 自身であり、二重メンテナンスの価値が無い。置き換えを選んだ。
- **UI は現状維持 (案 1)**: 重複表示が残り、[[0003]] の成果がユーザに見えない。
- **UI は USGS のみ表示 (案 2)**: 重複は避けられるが EMSC が地図に出ず、全球化の目的に反する。EMSC だけが捉える地域 (欧州・地中海周辺の小規模地震) が抜ける。
- **`source:source_id` をキーに残し `canonical_of` で結ぶ**: クライアントがメンバーと event の二重簿記を持つことになり、SSE の `update` をどちらのキーで適用するか曖昧になる。
- **出典を event JSON に埋め込む**: 1 リクエストで済むが、event ごとに同じ文言を繰り返す。`/api/v1/sources` は静的で、1 回の取得で足りる。

## 影響とトレードオフ

- **破壊的変更**: 地震 API の payload が変わる。外部の消費者は無い前提だが、README の API 記述を更新した。
- **`id` の安定性**: 整数 `id` は DB の identity で、dev volume を作り直すと振り直される。クライアントは再接続時の `resync` で全件取り直すため、永続 ID を前提にした機能 (ブックマーク等) を将来作るなら別途 UUID などを検討する。
- **payload の増加**: `members` を各 event に埋め込むため、応答サイズはメンバー数に比例して増える。現状は最大 2 メンバーで問題ない。
- **出典の取得が 1 リクエスト増える**: `fetchSources()` は失敗しても無視する (出典は補助情報) が、その場合 EMSC の出典が表示されない。恒久的に失敗する構成なら CC BY の義務を果たせないので、監視対象にするべき。
- **`first_seen_at` / `last_seen_at` の意味が変わる**: ソース行ではなく event 単位の値になる。
- **メンバーの詳細はソース行に残る**: `sea.earthquake` の全項目 (USGS の `tsunami`、`felt` など) は優先メンバーの分だけ投影される。非優先メンバーの詳細を UI で見せるには `members[]` を拡張する必要がある。

## 関連ADR

- [[0002]] — `/api/v1/pipeline/status` の `matched` 内訳と ack 契約。
- [[0003]] — canonical event と投影規則。
- [[0004]] — 出典・ライセンスの供給元 (`/api/v1/sources`)。
- [[0007]] — メンバーとして表示される 2 つ目のソース (EMSC)。
