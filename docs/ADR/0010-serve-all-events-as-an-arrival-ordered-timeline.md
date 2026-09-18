---
title: 全種別のイベントを到着順の統合タイムラインとして keyset ページングの API と /globe の Timeline タブで提供する
status: accepted
date: 2026-09-18
depends-on: ["0005", "0009"]
---

# 0010: 全種別のイベントを到着順の統合タイムラインとして keyset ページングの API と /globe の Timeline タブで提供する

## コンテキスト

`docs/internal/idea2.md` §6「/globe との接続」は、警報・地震・災害を同じ海図に載せることを目標にしている。[[0005]] で canonical 地震、[[0009]] で GDACS hazard が `/globe` に乗り、NOAA alert と合わせて 3 種別が揃った。しかしサイドペインは種別ごとのタブで、並び順もばらばらだった (地震はマグニチュード降順、hazard は `modified_at` 降順、alert は NWS 優先度順)。「いま何が起きているか」を一望する手段が無く、ユーザは「既存のイベントすべてが Twitter のタイムラインのように時系列で上から流れる」ビューを求めた。

設計上の論点は、統合ビューの置き場所、対象種別、時系列の基準時刻、改訂の扱い、新着の挿入方法、バックエンドの構成、履歴の深さ、終了イベントの扱い、地震の密度対策、フィルタ、行クリックの挙動、日付区切り、種別横断の重大度尺度、GDACS 地震 hazard の重複、の 14 点で、いずれもユーザに選択肢を提示して決めた。

制約は [[0005]] と同じで、コア (Gleam) と Web (SvelteKit) を別のエージェントが並列に実装するため、API 契約を実装前に文書として固定した。また [[0002]] のとおり判定は Gleam に置き、SQL は制約と CRUD に限る。RSS adapter は health エンドポイントしか持たないスタブで、イベントが存在しないため対象外とした。

## 決定

### ユーザの選択

| 論点 | 決定 |
|---|---|
| 置き場所 | `/globe` サイドペインに `Timeline` タブを追加し、タブ列の先頭に置く。既存 4 タブと既定タブは変えない |
| 対象 | canonical 地震 (`sea.event`)、GDACS hazard (`sea.hazard`)、NOAA alert (`sea.alert`)。RSS は含めない |
| 基準時刻 | 到着時刻 `first_seen_at` 降順 (MatrixWhale が初めて知った時刻)。発生時刻や最終更新時刻ではない |
| 改訂 | 行はその場で内容を差し替え、`updated` バッジを付ける。先頭へは動かさない |
| 新着 | リストが先頭にあれば即時挿入、スクロール中は `pending` に溜めて「N new」ピルを出す。ピルで反映して先頭へ戻る |
| バックエンド | 新規 `GET /api/v1/timeline` (keyset ページング)。ライブ更新は既存 3 本の SSE を再利用し、新しいハブは作らない |
| 履歴 | 無限スクロールで DB の保持期限まで (地震は 7 日、hazard と alert は削除していない) |
| 終了 | 終了した alert (`ended_at` あり) と非 current の hazard は薄く描いて `ended` バッジ。`status = 'deleted'` の地震は除外 |
| 地震下限 | 既定 M2.5+ (地震タブと同じ)。チップで All / 2.5+ / 4.5+ |
| フィルタ | 種別トグル (最低 1 つは残す) と重大度の下限しきい値チップ (All / Moderate+ / Severe+ / Extreme)。ページが欠けないよう全てサーバ側クエリパラメータ |
| 行クリック | 地図フォーカス + 既存の種別別詳細ビューへタブ内でドリルイン。戻るとスクロール位置を復元 |
| 区切り | 日付ヘッダは置かず、各行に短い相対時刻 (`15m`、`2h`)。hover で絶対時刻 |
| 重大度尺度 | CAP 準拠の 4 段階 + unknown。地震はマグニチュード帯で写す |
| GDACS 地震 | `hazard_type = 'earthquake'` の hazard は常に除外 (canonical 地震として既に流れる) |

### 種別横断の重大度

`unknown(0) < minor(1) < moderate(2) < severe(3) < extreme(4)`。地震は `magnitude` null → unknown、4.5 未満 → minor、4.5 以上 6.0 未満 → moderate、6.0 以上 7.0 未満 → severe、7.0 以上 → extreme。hazard は `cap_severity` をそのまま (GDACS に moderate は無い)。alert は NOAA の `severity` を小文字化し、`Unknown` は unknown。`min_severity=X` は rank が X 以上の行を残す。Gleam (`domain/timeline.gleam`) と TypeScript (`src/lib/timeline/severity.ts`) に同じ表を置き、境界値 (null、-0.3、4.49、4.5、5.99、6.0、6.99、7.0、9.1) を双方の単体テストで固定した。

### API 契約

- `GET /api/v1/timeline?limit=1..200&before=<cursor>&kinds=earthquake,hazard,alert&minmag=<number>|all&min_severity=minor|moderate|severe|extreme`。既定は `limit=50`、全種別、`minmag=2.5`、重大度フィルタなし。不正値は 400 (`{"error": "..."}`)、GET 以外は 405、成功は既存の `etag_json_response` (ETag + `Cache-Control: no-cache`)。
- 応答は `{"items": [<TimelineItem>], "next_cursor": "<opaque>" | null, "generated_at": "<RFC3339>"}`。`items` は `(first_seen_at DESC, kind DESC, key DESC)` 順。`next_cursor` は keyset 1 段目の行数が `limit` に達したときだけ付く。
- `TimelineItem` は `kind`、`key` (`earthquake:<event.id>` / `hazard:<source>:<source_id>` / `alert:<alert.id>`)、`seen_at` と `seen_at_ms` (`first_seen_at`)、`severity`、`ended` に加え、`kind` に応じて `earthquake` / `hazard` / `alert` を 1 つ持つ。中身は `/api/v1/earthquakes/recent`、`/api/v1/hazards/recent`、`/api/v1/alerts/active` の要素と同じ JSON (既存の `to_json` をそのまま使う)。NOAA の id は URN でコロンを含むため、`key` は最初のコロンで種別を切り、alert は残り全体を id とする。
- cursor は `"<first_seen_at::text>\n<kind>\n<key>"` の base64url (パディングなし)。クライアントは中身を解釈せず `before` にそのまま返す。

### keyset ページング (`repository/timeline_reader.gleam`)

1. 3 テーブルを `(kind, key, first_seen_at)` に射影した `UNION ALL` に対し、`WHERE kind = ANY($kinds) AND ($cursor IS NULL OR ROW(first_seen_at, kind, key) < ROW($cursor::text::timestamptz, $kind, $key)) ORDER BY first_seen_at DESC, kind DESC, key DESC LIMIT $limit`。`first_seen_at::text AS first_seen_at_text` を返し、cursor はその文字列を保持する。
2. 種別ごとに key リストで本体を取り直し (`sea.event WHERE id = ANY`、`sea.hazard WHERE (source, source_id) IN unnest`、`sea.alert WHERE id = ANY`)、1 段目の順に並べ直す。2 段目で消えた key は落とす。
3. 種別ごとの WHERE は `status IS DISTINCT FROM 'deleted'`、`($n IS NULL OR magnitude >= $n)`、`hazard_type <> 'earthquake'`、`($n::text[] IS NULL OR cap_severity = ANY($n))` の形に限り、しきい値 (`min_severity` → マグニチュード下限 4.5 / 6.0 / 7.0、`cap_severity` と NOAA `severity` の値リスト) は Gleam で決める。`CASE` / `COALESCE` は書かない。

索引は `db/schema.sql` に `idx_event_first_seen_at (first_seen_at DESC, id DESC)`、`idx_hazard_first_seen_at (first_seen_at DESC)`、`idx_alert_first_seen_at (first_seen_at DESC)` を足し、`make db-diff name=timeline_first_seen` で `db/migrations/20260918121737_timeline_first_seen.sql` を生成した。

### Web

- `src/lib/pane/state.ts`: `PANE_TABS` の先頭に `timeline`。どの種別も timeline タブからドリルインでき (`TAB_CANDIDATES` に `timeline` を末尾追加)、`isDetailOpen` / `closeKindForTab` は timeline タブで開いている種別を選択状態から判定する。
- `src/lib/{alerts,earthquakes,hazards}/store.svelte.ts`: `subscribeRaw(listener)` を追加し、SSE ハンドラの先頭でストア自身のフィルタより前に生のレコードを流す (`alert.new/update/ended` → `new/update/ended`、地震と hazard は `new/update` に加え `resync`)。
- `src/lib/timeline/store.svelte.ts`: `items` / `pending` / `updatedKeys` / `nextCursor` / `filters` を持つ `TimelineStore`。`new` はフィルタ通過時に `pending` へ、`update` は `items` か `pending` の同 key を差し替えて `updatedKeys` に追加、フィルタから外れた改訂 (M 下方修正、削除) は行を消す。`resync` は先頭ページを取り直して key で upsert。フィルタ変更は全消去して再取得。
- `src/lib/components/pane/TimelineList.svelte`: チップ 3 列、sticky の「N new」ピル、`ListRow` の行 (種別マーカー、`<time datetime title>`、`updated` / `ended` バッジ、ended 行は不透明度 50%)、`IntersectionObserver` の末尾センチネルで `loadMore()`、`No more events` / `No events yet`。
- `SidePane.svelte`: 種別別の詳細を `{#snippet}` に切り出して timeline タブと共用。timeline のドリルインは行に埋め込まれたレコードを優先し、ライブストアに無い (終了済み・7 日超) イベントでも詳細を開ける。`globe/+page.svelte` の `select*` はストアにレコードが無くても選択 id を立て、地図の fly-to だけを省くように改めた。
- テスト: Vitest に severity 表 / store 14 件 / 各ストアの `subscribeRaw` 1 件ずつ、Playwright に `tests/timeline.spec.ts` 7 件 (先頭タブと並び順、センチネルでの 2 ページ目、先頭での即時挿入、スクロール中のピル、`update` のバッジ、ドリルインと戻る、種別チップの `kinds=` パラメータ)。SSE の注入は `tests/fixtures.ts` の `SseInjector` (再接続ごとにキューを流す) で行う。

## 根拠（調査結果・出典）

- **契約先行の並列開発が再び成立した**: コアは `gleam test` 161 件と `make test-core` (使い捨て PostGIS コンテナ、6 migration / 32 statement 適用) 161 件、Web は `svelte-check` 0 エラー、Vitest 186 件、Playwright 15 件 (既存 8 + 新規 7) が、互いの完成を待たずに通った。統合後に契約の食い違いは無かった。
- **実 DB での実測**: 稼働中の DB (地震 4,067 件、地震以外の hazard 1,008 件、alert 366 件のうち終了 55 件) に対し、keyset 1 段目 (`limit=50`、`minmag=2.5`) は索引なしの seq scan + top-N heapsort で 18.7 ms、shared hit 484 ブロックだった。索引適用前でも実用範囲だが、行数が桁で増えれば索引が効く。
- **`ORDER BY` の落とし穴**: 1 段目を `SELECT ..., first_seen_at::text` と書くと出力列名が `first_seen_at` のままになり、`ORDER BY first_seen_at` が **テキスト表現** を比較する (`EXPLAIN` の Sort Key に `(first_seen_at)::text` が出た)。WHERE 側は timestamptz 比較なので、順序が一致するのは UTC 固定・末尾ゼロ省略・`+` < `.` < 数字という文字順の偶然に依存する。`AS first_seen_at_text` と別名を付け、`ORDER BY` が CTE の timestamptz 列を指すよう直した。
- **pog と型推論**: cursor を `$7::timestamptz` と書くと Postgres がパラメータ型を timestamptz と宣言し、pog の `pog.text` が `UnexpectedArgumentType` で拒まれる。既存の `($1 || ' hours')::interval` と同じく `$7::text::timestamptz` にして、pog にはテキストとして渡しつつマイクロ秒精度の往復を保った。
- **同一 `first_seen_at` の束**: 取り込みは chunk 単位のトランザクションで `now()` がトランザクション開始時刻になるため、backfill では数千行が同じ `first_seen_at` を持つ。`(first_seen_at, kind, key)` の 3 列 keyset でなければ同じページを繰り返す。統合テストは 7 行を同一時刻で seed し `limit=2` で全行が 1 回ずつ出ることを固定した。
- **到着時刻を選んだ理由**: 地震は発生から USGS / EMSC の公開まで数分〜数十分遅れ、GDACS は 5 分ポーリングで episode が更新されるため、発生時刻順では新着が先頭に来ない。「流れてくる」体験は到着順でしか成立しない。
- **CAP の 4 段階**: NOAA の `severity` と GDACS の `cap_severity` ([[0009]]) が既に CAP の語彙 (Minor / Moderate / Severe / Extreme) を使っているので、地震だけを写せば横断尺度になる。マグニチュード帯の境界 4.5 / 6.0 は地震タブの灯火区分 (`usgs_pipeline.md` 決定 10) と一致させ、7.0 を extreme の閾値に置いた。

## 検討した代替案

- **バックエンド変更なしでフロントの 3 ストアをマージ**: 最小工数だが、地震ストアは発生時刻の 24h 窓と M2.5+ で絞って保持するため、到着順の並びが窓に切られ、過去分も遡れない。ストアの窓とタイムラインの窓が別物である以上、サーバ側で統合する必要があった。
- **統合 SSE `/api/v1/timeline/stream` を新設**: クライアントは 1 本で済むが、Gleam に 4 つ目のハブとファンアウトが増え、3 本の既存ストリームと二重に配信する。既存ストリームの payload には `first_seen_at` が含まれ、`subscribeRaw` で十分だった。
- **発生時刻 (`occurred_at` / `onset_at` / `sent`) で並べる**: 「いつ起きたか」の履歴としては正しいが、新着が先頭に来ない場合があり、backfill で古い地震が上に割り込む。
- **改訂を別行として先頭に流す (アクティビティログ)**: 改訂履歴が見えるが、地震の M 改訂と GDACS の episode 更新で行数が膨れ、タイムラインが同じイベントで埋まる。その場更新 + バッジを選んだ。
- **新ルート `/timeline`**: 見た目は最も Twitter に近いが、地図との連携が `?focus=` 遷移になる。「新しいレイヤはタブで」というサイドペインの方針 (37c861d) と一致させた。
- **cursor を `first_seen_at_ms` の整数で持つ**: ミリ秒に丸めると同一ミリ秒内の順序が壊れる。Postgres が印字したテキストをそのまま往復させる方が単純で正確だった。
- **cursor 到達判定を 2 段目の `items.length` で行う**: 2 段目で行が消えた (削除との競合) ページで `items.length < limit` になり、クライアントが誤って終端と判断する。1 段目の行数で判定する契約に改めた。

## 影響とトレードオフ

- **`UNION ALL` は常に 3 テーブルを走査する**: `kinds` の絞り込みは UNION の外側で `kind = ANY($n)` として掛けるため、種別を減らしても他の分岐の走査は省けない。現状の行数では 20 ms 未満で、`kinds` を分岐の有無に変える最適化は行数が増えてから検討する。
- **`ORDER BY` に計算列が混ざる**: `kind` と `key` は文字列連結なので、`first_seen_at` の索引は WHERE の範囲絞りには効くが、UNION 全体の並べ替えは top-N heapsort のまま残る。
- **2 段目は N+1**: 地震の本体は `event_writer.to_view` で event ごとにメンバーを引く (既存の `/recent` と同じ)。1 ページ 50 件なので許容した。
- **`first_seen_at` の意味**: 再構築した dev volume では backfill 時刻がそのまま「到着」になり、起動直後のタイムラインは数千件の同時刻の束から始まる。これは到着順の定義どおりで、発生時刻を見たい場合は各行の詳細か種別タブを使う。
- **`subscribeRaw` は 3 ストアへの結合**: タイムラインは 3 ストアの SSE 接続に相乗りするので、ストアが接続されていないページでは動かない。現状 `/globe` でのみ使う前提。
- **タブが 5 つになった**: 380px のペインで「Earthquakes」が収まらなくなり、タブのフォントを 13px から 11px に落とした。
- **選択の挙動変更**: `select*` がストアに無い id でも選択状態を立てるため、`?focus=<未知の id>` は以前の無視から「詳細なしで選択」に変わる。timeline 以外のタブではリストが出るだけで実害はない。
- **稼働中スタックへの反映は別作業**: migration は次回の `docker compose up` で `migrate` サービスが適用し、`matrix_whale` と `web` のイメージは再ビルドが要る。本 ADR の時点では未反映。
- **重大度チップに Minor+ は無い**: unknown は magnitude null の地震だけで、`minmag=2.5` の既定では出ないため、`Minor+` チップを置く価値が無いと判断した。`minmag=all` + `min_severity=minor` の組み合わせは API では有効。

## 関連ADR

- [[0002]] — 判定は Gleam、SQL は制約と CRUD。keyset のしきい値と値リストを Gleam で決める根拠。
- [[0005]] — canonical 地震の API 契約と、契約先行の並列開発。`earthquake` payload はその `<Event>` そのもの。
- [[0009]] — hazard の API 契約と `cap_severity`。`hazard` payload はその `<Hazard>` そのもの。
