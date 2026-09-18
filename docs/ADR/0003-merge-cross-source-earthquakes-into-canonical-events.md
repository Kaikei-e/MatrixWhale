---
title: クロスソースの地震を canonical event と member link に統合し EMSC EventID の misfit で照合する
status: accepted
date: 2026-09-18
depends-on: ["0002", "0004"]
---

# 0003: クロスソースの地震を canonical event と member link に統合し EMSC EventID の misfit で照合する

## コンテキスト

`docs/internal/idea2.md` §6 は重複排除を二段構えにすると定めている。一段目は「ソース + ソース側 ID」による取り込み口での排除 ([[0002]])、二段目は統合層でソースをまたいだイベント照合である。`docs/internal/usgs_pipeline.md` §5.3 は二段目を明示的に先送りし、`sea.earthquake` の主キー `(source, source_id)` と `contributing_ids` 列だけを将来のために予約していた。

二つ目の地震ソースとして EMSC (Euro-Mediterranean Seismological Centre) を追加した時点 ([[0007]]) で、この先送りは解消しなければならなくなった。USGS と EMSC は同じ物理的な地震を別々の ID で報告する。しかも両者の ID 体系は交わらない。

- USGS の `id` は「ネットワーク識別子 + ネットワーク割当コード」(例: `us7000ti1p`) で、`ids` プロパティには寄与ネットワークの ID (`,ci15296281,us2013mqbd,`) が並ぶ。
- EMSC の `unid` は `YYYYMMDD_NNNNNNN` 形式の EMSC 内部 ID で、`source_id` / `source_catalog` は寄与機関 (CSN、BMKG、AFAD など) 自身の ID を指す。USGS の ID が含まれることは EMSC-RTS カタログでは稀である。

つまり USGS↔EMSC では ID の完全一致はほぼ当てにできず、時刻・位置・マグニチュードによるファジー照合が主経路になる。一方で GDACS のように `sourceid` に USGS の ID をそのまま持つソースもあり (実測で `us7000ti1p` が入っていた)、ID 一致が効くケースも将来確実に出る。

照合しないままでは `/globe` に同じ地震が 2 点描かれ、灯火の点滅ルールも二重に走る。ユーザは「canonical event + link テーブル」で表現し、照合は「ID 完全一致 → ローカル misfit」で実装し、表示値は `sea.source.priority` で固定優先する方針を選んだ。

制約として、判定ロジックは SQL ではなく Gleam に置く ([[0002]] と同じ方針)。照合・スコアリング・投影はすべて純粋関数として単体テスト可能でなければならない。

## 決定

### スキーマ

Atlas のマイグレーション `20260917180345_canonical_events.sql` で次の 2 表を追加した。

- `sea.event`: `id BIGINT GENERATED ALWAYS AS IDENTITY` を主キーとする統合イベント。`kind`、`preferred_source` (FK `sea.source`)、`preferred_source_id`、および投影列 (`magnitude`、`magnitude_type`、`occurred_at(_ms)`、`updated_at(_ms)`、`place`、`title`、`status`、`event_type`、`longitude`、`latitude`、`depth_km`) を持つ。投影列は優先メンバーのキャッシュで、`/api/v1/earthquakes/recent` が JOIN なしで絞り込めるようにするためにある。
- `sea.event_member`: `PRIMARY KEY (source, source_id)`、`event_id` (FK `sea.event` ON DELETE CASCADE)、`(source, source_id)` から `sea.earthquake` への FK (ON DELETE CASCADE)、`matched_by` (`origin` | `id` | `misfit`)、`misfit`。1 つのソース行はちょうど 1 つの event に属する。

候補検索のためのインデックスは `idx_event_match_window (occurred_at_ms, latitude)` とした。当初は `(occurred_at, latitude, longitude)` だったが、クエリが `occurred_at_ms` で絞る以上そのインデックスは一度も使われず、seq scan になっていた (後述)。

### 照合アルゴリズム (`src/matching/earthquake_matcher.gleam`、純粋関数)

ソース行が書き込まれるたびに、同じトランザクション内で `event_writer.link_batch` が次を行う。

1. **ID 完全一致**: 候補行の `contributing_ids ∪ {source_id}` が、いずれかの既存メンバーの `contributing_ids ∪ {source_id}` と交わるなら、その event に `matched_by = "id"` で付ける。
2. **misfit 照合**: `|Δt| ≤ 60 s` かつ `|Δlat| ≤ 1.5°` かつ `|Δlon| ≤ 1.5°` (経度は ±180° をまたいで比較) の event を候補とし、次のスコアを計算する。

   ```
   misfit = dloc_km / 105 + dt_s / 13 + dmag / 0.8
   ```

   `dloc_km` は haversine 距離、`dmag` は `|Δmag|` (どちらかにマグニチュードが無ければ項は 0 だが「範囲内」とは数えない)。3 つの差分のうち閾値の 1.2 倍 (126 km、15.6 s、0.96) に収まる個数を `m2` とし、`m2 ≥ 2` を満たす最小 misfit の候補に、その event がまだ同じソースのメンバーを持っていない場合に限り `matched_by = "misfit"` で付ける。
3. どちらにも該当しなければ新しい `sea.event` を作り、その行を `matched_by = "origin"` のメンバーにする。

SQL 側は `occurred_at_ms BETWEEN $1 AND $2 AND latitude BETWEEN $3 AND $4` の範囲検索だけを担い、経度の wrap 判定と misfit 計算は Gleam で行う。

### 投影 (`src/matching/projection.gleam`、純粋関数)

- 優先メンバー = `sea.source.priority` が最も高いメンバー (usgs 100 > emsc 90、[[0004]])。同点なら `updated_at_ms` が新しい方。`status = "deleted"` のメンバーは、全員が deleted でない限り優先メンバーに選ばない。
- event の `updated_at_ms` はメンバーの最大値。クライアントはこれを revision ガードとして使い続ける。
- `status` は全メンバーが deleted のときだけ `"deleted"`。
- `sources` は優先メンバーを先頭にした重複なしのソース一覧。

メンバーが追加・更新されるたびに再投影して `sea.event` を UPDATE し、SSE では `update` として配信する。統計は `/api/v1/pipeline/status` の `matched` に既存 event へ紐付けた件数を出す。

### 保持期間

`earthquake_reader.cleanup` は `sea.earthquake` と同様に `sea.event` も `occurred_at` から 7 日で削除する。メンバーは両方向の FK の CASCADE で消える。

## 根拠（調査結果・出典）

- **閾値の出典**: EMSC が運用する EventID サービス (異機関の地震 ID を対応付ける Web サービス) の OpenAPI 定義に既定値が明記されている。候補収集 `collect_dtime = 60` 秒、`collect_dloc = 1.5` 度、スコア `misfit = dloc/misfit_dloc + dt/mistfit_dtime + dmag/misfit_dmag` で `misfit_dloc = 105` km、`mistfit_dtime = 13` 秒、`misfit_dmag = 0.8`、採用条件 `m2 >= 2` (3 指標のうち 1.2 倍以内に収まる数)。同定義は「M4.5 以上でテストした既定値」と注記している。https://www.seismicportal.eu/eventid/ および https://www.seismicportal.eu/eventid/api/v1/openapi.json
- 調査時にこのサービスを実際に呼び、EMSC `unid` 480233 (2016 年ミャンマー・インド国境 M6.7) が USGS `us10004b2n`、INGV、GFZ、ISC に対応付き、時刻差 0.1〜1.9 秒、距離差 1〜11 km、M 差 0.1〜0.5 で全て閾値内だったことを確認した。既定値をそのまま使う根拠である。
- **固定窓への批判**: 「1 分・100 km」の固定窓でカタログを突き合わせる素朴な手法は不十分で、最適閾値はタスク依存だと指摘する論文がある。https://www.frontiersin.org/journals/earth-science/articles/10.3389/feart.2022.820277/full 。本 ADR は固定窓を候補収集にだけ使い、採用判定は正規化した misfit と `m2` で行うことでこの批判の主要部分を避けている。
- **ID 体系**: USGS ComCat の `id` / `ids` / `sources` / `status` の定義。https://earthquake.usgs.gov/data/comcat/index.php 。GDACS の地震レコードが `sourceid` に USGS の ID を保持することはライブ API で確認した (`https://www.gdacs.org/gdacsapi/api/events/geteventdata?eventtype=EQ&eventid=1566678`)。
- **実測**: dev volume を作り直して 3 アダプタを稼働させた結果、USGS 2,247 行と EMSC 2,408 行から 4,207 event が生成され、EMSC 行のうち 448 件が misfit で既存の USGS event に紐付いた (ID 一致は 1 件)。例として 2026-09-17 の M6.5 Nikolski (Alaska) は USGS `us7000ti1p` (`origin`) と EMSC `20260917_0000195` (`misfit` 0.13、時刻差約 1 秒) が同一 event になり、投影は USGS 側の値である。
- **性能上の発見**: EMSC の 7 日 backfill (2,413 件) を 1 トランザクションで処理したところ、個々の文は最長 456 ms なのにトランザクション全体が約 5 秒に達し pog の既定クエリタイムアウト (5,000 ms) で 503 になった。原因は候補検索が `occurred_at` のインデックスを使えず seq scan だったこと (EXPLAIN ANALYZE で確認) と、行ごとに 8〜10 クエリ走ることの積である。インデックスを `(occurred_at_ms, latitude)` に直し、書込を 250 件ずつのトランザクションに分割し ([[0002]])、新規行では `find_member_link` を省略した結果、同じ 2,413 件が 4.9〜7.1 秒で 200 を返すようになった (コミット fdd2723)。

## 検討した代替案

- **EMSC EventID サービスをライブで呼ぶ**: 実装は最も軽いが、照合が外部 API の可用性とレート制限 (未公開) に依存する。地震以外のイベント種別 (GDACS の洪水・火山、将来の WIS2) には使えないため、統合層の共通機構にならない。既定値をローカルに持てば同じ結果を決定的・オフラインで得られるので不採用。
- **ソース行に `canonical_of` 列を持つだけ**: スキーマ変更は最小だが、統合後の値 (優先メンバーの投影) を置く場所がなく、`/recent` のたびに全メンバーを再評価することになる。UI が canonical を直接扱う要件 ([[0005]]) と相性が悪い。
- **照合結果をログと統計に出すだけ**: スキーマを変えずに精度を観察する案。今回は 2 ソース目が実装済みで UI 重複が実害になるため、観察だけでは要件を満たさない。
- **表示値を「最新 revision を採用」にする**: ソースに関係なく最後に更新されたメンバーの値を出す案。EMSC の速報更新のたびに位置や M が USGS と EMSC の間で振れ、ユーザから見て表示が安定しない。優先度固定なら「USGS がある限り USGS の値」と説明できる。
- **`status = reviewed` で昇格する**: USGS の automatic より EMSC の reviewed を優先する案。EMSC-RTS の `status` 相当情報は乏しく (今回は `automatic` 固定)、判定が複雑になる割に効果が見込めないため見送り。将来ソースが増えたら再検討する。
- **PostGIS を導入して空間検索する**: 候補数は ±60 秒の時間窓でまず数十件に絞られるため、B-tree の範囲検索と Gleam の haversine で十分。拡張追加は Atlas の制約 ([[0001]]) とも噛み合わないので今回は入れない。

## 影響とトレードオフ

- **得るもの**: `/globe` と API で同じ地震が 1 点になる。照合・投影が純粋関数なので閾値の変更や新ソースの追加が単体テストで検証できる。`members[].matched_by` と `misfit` を保存するため、誤照合の事後分析ができる。
- **閾値の適用範囲**: EMSC の既定値は M4.5 以上で検証されたもの。小さな地震では群発時の過剰統合や、位置精度の低い速報での取りこぼしが起こり得る。`matched_by = "misfit"` と `misfit` 値を残しているので、分布を見て閾値を調整する余地がある。
- **先着が origin になる**: 先に届いたソースが event を作り、後から高優先のメンバーが来ると投影が切り替わる。クライアントには `update` として通知されるが、event の `id` は変わらない。
- **1 event につき 1 ソース 1 メンバー**: 同じソースの 2 行が同じ event に付くことはない。同一ソース内の分裂 (USGS が後から別 ID で再登録する等) は別 event になる。
- **行ごとの候補検索**: 1 行につき候補 SELECT が走る。インデックス修正後は十分速いが、WIS2 級の流量では候補をバッチで先読みする最適化が必要になる可能性がある。
- **削除の意味論**: EMSC の `delete` はメンバーの `status` を `deleted` にするだけで、event は他のメンバーが生きている限り残る。全メンバーが deleted になったときだけ event が `deleted` になり、クライアントが除外する。
- **event id の安定性**: `id` は DB の identity なので、dev volume を作り直すと振り直される。クライアントは `resync` で全件取り直す前提のため実害はない。

## 関連ADR

- [[0001]] — `sea.event` / `sea.event_member` は Atlas のマイグレーションとして追加した。
- [[0002]] — 照合は intake の書込トランザクション内で走り、チャンク分割の恩恵を受ける。
- [[0004]] — 投影の優先順位は `sea.source.priority` から取る。
- [[0005]] — canonical event を API と UI の単位にする決定。
- [[0007]] — 照合対象となる 2 つ目のソース (EMSC) の取り込み。
