---
title: GDACS を polling 型アダプタとして追加し、geometry の取得はコアが決める pending 一覧で駆動する
status: accepted
date: 2026-09-18
depends-on: ["0002", "0006", "0009"]
---

# 0008: GDACS を polling 型アダプタとして追加し、geometry の取得はコアが決める pending 一覧で駆動する

## コンテキスト

`docs/internal/idea2.md` §7 の着手順 1 は USGS・EMSC・GDACS で、USGS（polling）と EMSC（push、[[0007]]）は済んでいる。GDACS（Global Disaster Alert and Coordination System、JRC と OCHA の共同枠組み）は地震・熱帯低気圧・洪水・火山・山火事・干ばつ・津波を 3 段階の alert level 付きで配信する多災害ソースで、GeoJSON を返す無償の JSON API がある。求められるのは出典表示だけである。

公開インターフェースを 2026-09-18 にライブで確認した結果、これまでのアダプタとは前提がいくつか違った。

- API のベースは `https://www.gdacs.org/gdacsapi/api`、OpenAPI 3.0 の仕様が `swagger/v1/swagger.json` にある。認証・API キーは不要で、レート制限も推奨ポーリング間隔も文書化されていない。JSON エンドポイントには `ETag` / `Last-Modified` / `Cache-Control` が付かず、条件付き GET は使えない（RSS の `xml/rss.xml` には `ETag` がある）。
- 一覧は `events/geteventlist/{search|latest|events4app|MAP}` で、`pageSize` は最大 100、`todate` 降順、`pageNumber` は 1 始まり、該当なしは `204 No Content`。`search` は `fromDate` / `toDate` でイベント自身の期間を絞り、`latest` は `datemodified`（ISO 日時可、空なら直近 6 か月）で更新時刻を絞る。`alertlevel` は必須で、省くと 204 になる。
- `eventid` は災害の一生を通じて安定し、`episodeid` が更新単位（サイクロンは 6 時間ごとに新 episode）。一覧は各イベントの現在の episode を返し、`datemodified` が変更検知の手掛かりになる。version 列はない。
- 一覧系（`search` / `latest` / `events4app`）は `source` / `sourceid` を空文字で返す。USGS の ID（例 `us7000ti1p`、`source == "NEIC"`）が入っているのは `polygons/getgeometry` の各 Feature のプロパティ、`geteventdata`、種別ごとの `MAP` だけである。
- `getgeometry?eventtype&eventid&episodeid` は FeatureCollection を返し、`Class` プロパティで `Point_Centroid`、`Poly_Circle`、`Poly_SMPInt_<n>`（ShakeMap 強度帯）、`Poly_Affected` などを区別する。204 のこともある。
- 種別を `eventlist=EQ;TC;FL;VO;WF;DR` と並べると 14 日分で 1,202 件（13 ページ）返るが、`TS` を加えると同じ問い合わせが数件の EQ に縮み、`VO;WF;DR;TS` は 204、`latest?eventlist=TS` 単独は 404 になる。`search?eventlist=TS` 単独は 204（該当なし）で整形式。
- 14 日分の種別内訳（`search`、実測）は EQ 178、TC 8、FL 37、VO 1、WF 731、DR 13 で、山火事が全体の 7 割を占める。
- 利用規約（`documents/2025/GDACS_Terms_of_use_Mar_25.pdf`）は免責のみで再配布条項がない。API quickstart（`Documents/2025/GDACS_API_quickstart_v2.pdf`）は出典表示 "Global Disaster Awareness and Coordination System, GDACS" だけを求め、RSS は `<copyright>public domain</copyright>` を掲げる。

アダプタは [[0002]] の方針どおり raw forwarder に徹し、重複排除も「どの episode の geometry がまだ無いか」の判断もコアに置きたい。一方で geometry は episode ごとに 1 リクエスト増えるので、gdacs.org への負荷は 1 本のリミッタで抑える必要があった。保存先の二層モデルは [[0009]] で決めた。

## 決定

GDACS 専用の Go アダプタ `gdacs_adapter` を追加し、一覧のポーリングを主経路、episode ごとの geometry 取得を背景経路とする。

- **一覧の取得**: 5 分ごと（`GDACS_POLL_INTERVAL`）に 2 つのクエリを順に全ページ回す。主クエリは `geteventlist/latest?eventlist=EQ;TC;FL;VO;WF;DR&alertlevel=green;orange;red&datemodified=<UTC 秒精度>`、津波は `geteventlist/search?eventlist=TS&alertlevel=...&fromDate=<now−14d>&toDate=<now+7d>`。`datemodified` は起動直後の 1 回だけ `now − GDACS_BACKFILL_DAYS`（既定 14 日）、以後は `now − 3 × ポーリング間隔`（重なりはコアが吸収する）。各ページを `POST /api/v1/gdacs_data/send`（共通エンベロープ、[[0006]]）で無加工転送し、`PollMeta.Backfill` は初回パスだけ `true`。
- **geometry の取得はコア駆動**: 一覧を送り終えたら次の tick まで、`GET /api/v1/gdacs_data/geometry/pending?limit=20` でコアから「geometry 未取得の episode」（`modified_at` 降順）を受け取り、`polygons/getgeometry` を 1 件ずつ叩いて `POST /api/v1/gdacs_data/geometry` に `{"eventtype","eventid","episodeid","http_status","geometry":<FeatureCollection|null>}` を最大 10 件ずつ送る。コアは 204 も「取得済み」として記録するので同じ episode を二度は求めない。アダプタは seen 状態を持たない。
- **1 本のリミッタ**: gdacs.org へのリクエストは常に 1 本 in-flight、前のリクエスト終了から次の開始まで 10 秒以上空ける（`GDACS_MIN_REQUEST_INTERVAL`）。一覧が常に優先で、geometry は空き時間に消化する。
- **失敗の扱い**: 一覧は 429 / 5xx / ネットワーク障害なら `poll.ComputeBackoff`（floor 30 秒、ceiling 10 分）で同じページを最大 3 回まで再試行し、それ以外の 4xx（400、404）は即座にそのクエリを諦めて次の tick に任せる。コアへの POST 失敗はそのクエリの残りページを諦める（次の tick が重なりつきで取り直す）。アダプタは落ちない。
- **コア側**: `sea.gdacs_event` へ生の行を upsert し、同一トランザクションで `sea.hazard` を再計算する（[[0009]]）。geometry が届いたら、Feature のプロパティにある `source` / `sourceid` で生の行の空の `origin_source_id` を埋め、hazard を再計算し、EQ については **このタイミングで** 既存の地震パイプライン（[[0002]] / [[0003]]）にも流す。`ids` に `gdacs:<event_id>` と（NEIC なら）USGS の ID を載せるので、canonical event へは ID 完全一致で結び付く。204 で geometry が無い場合も dual-write は行う（ID なし、misfit 照合に落ちる）。
- **ソースレジストリ**: `gdacs`、priority 80（USGS 100、EMSC 90 より下。EQ は NEIC 由来の二次情報のため）、license "Public domain (GDACS RSS); attribution requested"、出典文言 "Global Disaster Awareness and Coordination System, GDACS"、`redistributable = false`（[[0004]]）。
- **設定と配置**: `MATRIX_WHALE_URL`、`GDACS_CONTACT_EMAIL`（User-Agent）、`GDACS_API_URL`（テスト用）、`GDACS_BACKFILL_DAYS`、`GDACS_POLL_INTERVAL`、`GDACS_MIN_REQUEST_INTERVAL`。compose に `gdacs_adapter`（10.254.100.44）を足し、`go.work` に `./gdacs_adapter/app` を加える。コアのログ分類は `gdacs_adapter` を `gdacs` に写す。

## 根拠（調査結果・出典）

- OpenAPI 仕様: https://www.gdacs.org/gdacsapi/swagger/v1/swagger.json （UI は `swagger/index.html`）。`latest` のパラメータが `datemodified` であること、`search` の `fromDate` / `toDate`、`pageSize` 最大 100 はここから。
- quickstart: https://www.gdacs.org/Documents/2025/GDACS_API_quickstart_v2.pdf 「100 件を超える場合は `pagenumber` で複数回問い合わせる」「利用者はコレクションを保存し、更新日時を比較してから再度 API を呼ぶ」。フィード一覧 https://www.gdacs.org/feed_reference.aspx 。
- 利用規約と出典: https://www.gdacs.org/documents/2025/GDACS_Terms_of_use_Mar_25.pdf 、https://www.gdacs.org/About/termofuse.aspx 、RSS の `<copyright>public domain</copyright>` は https://www.gdacs.org/xml/rss.xml で確認。
- 公式 Python クライアント https://github.com/Kamparia/gdacs-api は `events4app` を「最新イベント」として使うが、フィルタ条件が GDACS アプリ基準で不透明（実測では 100 件中 82 件が山火事）。
- `search` と `latest` の違い（実測）: 2025-05-21 に始まり 2026-09-18 に更新された干ばつ（eventid 1017863）は、`search` の 14 日窓では返らず `latest` では返る。長期の DR / TC の更新を拾うには `datemodified` で絞る必要がある。
- `TS` を混ぜたときの縮退と `latest?eventlist=TS` の 404 は、同じ日に 2 回（45 秒間隔）ずつ再現した。`EQ;TS` は 200 だが件数が減る。
- `sourceid` の所在: `latest` / `search` / `events4app` の全 Feature で空、`getgeometry?eventtype=EQ&eventid=1566678&episodeid=1734522` の Point_Centroid / Poly_Circle / Poly_SMPInt_4 はすべて `source: "NEIC"`, `sourceid: "us7000ti1p"`、`geteventdata` も同じ。`MAP?eventtype=EQ` は 6 件すべてに入るが「現在のイベント」しか返さない。
- ポーリング量: 14 日分の `latest` 主クエリは 1,202 件 / 13 ページ（10 秒間隔で約 2 分強）。`datemodified` を今日にすると 1 ページ（97 件が山火事）。
- 検証: `go vet` と `go test`（httptest による GDACS とコアの偽サーバで、クエリパラメータ、1 始まりのページング、204、16 MB 上限、リミッタの間隔、pending の消化順と 10 件バッチ、`geometry: null` の符号化、backfill フラグが初回だけであること、429 → 200、503 × 3 で放棄、404 で即放棄して次のクエリは走ること）37 テスト通過。コア側は `make test-core` で `/gdacs_data/send` → `/gdacs_data/geometry` の順に投げて、EQ が geometry 到着後にだけ `sea.earthquake` に現れ、既存の USGS メンバーと `matched_by = "id"` で同じ `sea.event` に結び付き、`sea.hazard.external_ids` が `{usgs:<id>}` になることを HTTP レベルで確認。再構築したスタックでは初回 backfill の 12 ページがすべて `received == deduped + written + dropped` の ack で受理され、14 日分 1,152 イベントが入り、コアのログは `[source=gdacs][service=gdacs_adapter]` で分類された。geometry を手動で再送した M6.5 Nikolski, Alaska（eventid 1566678）は `contributing_ids = {gdacs:1566678, us7000ti1p}` で `sea.earthquake` に入り、USGS・EMSC と同じ canonical event に `matched_by = id` で結び付いた。

## 検討した代替案

- **`search` を 5 分ごとに回す**: 当初の案。フィルタが明示的で backfill と同じコードで済むが、`fromDate` / `toDate` はイベント自身の期間で絞るため、窓の外に始まった長期災害の更新を取りこぼす。`latest` は同じフィルタ語彙で `datemodified` を見るので乗り換えた。
- **`events4app`**: 公式クライアントが使う経路だが、GDACS アプリ向けの選別が入り何が落ちるか分からない。
- **RSS を条件付き GET で 2 分ごと**: `ETag` があり軽いが、GeoRSS / XML のパーサが要り、JSON API とフィールド名が違う。JSON API の生 Feature をそのまま `raw` に残す設計と合わない。
- **アダプタがメモリ上で seen を持って geometry をキューに入れる**: 実装は簡単だが、再起動のたびに 14 日分（1,000 件超 × 10 秒 ≒ 3 時間）を取り直す。コアが `geometry_fetched_at IS NULL` から pending を返せば再起動に耐え、判断はコアに残る（[[0002]]）。
- **`sourceid` を種別ごとの `MAP` で毎 tick 取る**: 7 リクエスト増え、しかも「現在のイベント」しか返さないので過去分に効かない。`geteventdata` を新規イベントごとに叩く案は、既に episode ごとに取っている `getgeometry` に同じ値が入っているので不要になった。
- **EQ の dual-write を一覧受信時に行う**: 最初はそうしていたが、一覧に `sourceid` が無いため USGS との結合が misfit 照合頼みになる。geometry 到着時に移すと、ID 一致で確実に結び付く代わりに地震レイヤへの反映が geometry 取得分（最新順なので通常は数十秒〜数分）遅れる。後者を取った。
- **リミッタなし、または並列取得**: GDACS に明示のレート制限はないが JRC の共有インフラであり、geometry を並列で叩く理由もない。1 本 10 秒はユーザの指定。
- **再試行を無制限にする**: `latest?eventlist=TS` が 404 を返すと判明したとき、無制限だとアダプタが永久にその 1 リクエストで詰まる。4xx は即放棄、5xx / 429 は 3 回で放棄に変えた。

## 影響とトレードオフ

- **得るもの**: 6 種別（津波は該当イベント待ち）の全球災害イベントが 5 分遅れで入り、`/globe` が地震以外の面と点を描けるようになった。GDACS の EQ が canonical event に ID で結び付くので、[[0003]] の ID 一致経路が実データで初めて働く。
- **geometry の遅延**: 10 秒に 1 件なので、初回 backfill 分（1,000 件超）の geometry が揃うまで 3 時間前後かかる。新しい episode は pending が `modified_at` 降順なので先に処理されるが、backfill 中は競合する。間隔は環境変数で詰められる。
- **山火事の偏り**: WF が 7 割を占め、既定の 14 日窓では毎 tick の 1 ページ目も山火事で埋まる。UI 側のフィルタで捌いており、取り込み側で種別ごとに窓を変えることはしていない。
- **`datemodified` の重なり**: `3 × ポーリング間隔` の重なりは、tick が遅延しても取りこぼさないための余裕で、重複はコアの revision 判定が `deduped` に落とす。GDACS 側で `datemodified` が単調でない場合は保証できない。
- **津波は未検証**: ライブで TS のサンプルが一度も取れておらず、Feature の形も `severitydata` も推定のまま。`search?eventlist=TS` が実イベントを返すことも未確認。
- **EQ の地震レイヤ反映は geometry 待ち**: アダプタが geometry を取り終えるまで、GDACS の EQ は hazard としては見えるが canonical event にはいない。geometry が 204 でも dual-write は行うので永久に欠けることはないが、アダプタが `send` と `geometry` の間で落ちると次回の pending 消化までずれる。
- **7 日より古い EQ は地震レイヤに入らない**: 地震パイプラインは発生から 7 日を過ぎたイベントを expired として捨てる（USGS / EMSC の backfill 窓と同じ）。GDACS は数か月前の地震の `datemodified` を定期的に bump するので、`latest` の 14 日窓にはそうした古い EQ も含まれ、hazard 行にはなるが `sea.earthquake` には現れない。統合時に「geometry が届いたのに地震行がない」として見つけ、仕様どおりと判断した。
- **`datemodified` の bump と `origin_source_id`**: 同じ bump のせいで、geometry 到着後に届く一覧の更新（常に `sourceid = ""`）が USGS ID を上書きして消していた。生の行を更新するときは、列ごとに「空でなければ新しい値、空なら現在の値」を Gleam で選んでから書く。geometry は bump のたびには取り直さない。
- **ヘルスチェックなし**: USGS / EMSC アダプタと同じく compose の `healthcheck` を持たない。
- **今後の課題**: TS の実サンプル確認、GDACS の `datemodified` の単調性、種別ごとのポーリング窓、pending の優先度（Orange / Red を先に）、`redistributable = false` を API で実際に効かせるかの判断（[[0004]]）。

## 関連ADR

- [[0002]] Gleam intake パイプライン。`(type, id, episode)` + `modified_at_ms` で一段目の重複排除に載せ、geometry の pending もコアが決める。
- [[0003]] canonical event。GDACS の EQ は geometry 到着時に USGS の ID で結合する。
- [[0004]] ソースレジストリ。`gdacs` の priority 80 と出典文言。
- [[0006]] `adapters/common`。バックオフ、コアクライアント、ack 検証、ログ転送を共有し、pending の GET だけをアダプタ内に足した。
- [[0007]] EMSC。push 型との対比で、こちらは USGS 型の polling に背景キューを足した形。
- [[0009]] 二層の hazard モデルと PostGIS。このアダプタが埋める先。
