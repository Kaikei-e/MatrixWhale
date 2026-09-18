---
title: 多災害イベントはソース専用テーブルから sea.hazard へ Gleam で正規化し、空間列は PostgreSQL 18 + PostGIS で持つ
status: accepted
date: 2026-09-18
depends-on: ["0001", "0004"]
---

# 0009: 多災害イベントはソース専用テーブルから sea.hazard へ Gleam で正規化し、空間列は PostgreSQL 18 + PostGIS で持つ

## コンテキスト

`docs/internal/idea2.md` §7 の着手順 1 は USGS・EMSC・GDACS である。GDACS（Global Disaster Alert and Coordination System）は地震だけでなく熱帯低気圧・洪水・火山・山火事・干ばつ・津波を扱い、各イベントは alert level（Green / Orange / Red）と種別ごとに単位の違う severity（M、km/h、ha、km² など）、centroid と bbox、別 API から取れる polygon（ShakeMap 強度帯、サイクロンの track と cone、洪水範囲）を持つ。

既存スキーマにはこれを受ける場所がなかった。

- `sea.earthquake` / `sea.event`（[[0003]]）は地震専用の形（magnitude、depth、単一の点）で、polygon も severity 段階も持てない。
- `sea.alert`（NOAA）は CAP 的で `geometry JSONB` も持つが、`source` 列がなく NOAA の ID 空間を主キーに直結している。2 つ目のソースを同居させるには主キーから作り直す必要があり、NOAA 側の writer / reader / UI に影響が及ぶ。

さらに、GDACS の後には各国の CAP フィード（WMO RAA 経由）や WIS2 が控えており、ソースごとの生の形をそのまま正規化テーブルに押し込むと、ソースを足すたびに正規化テーブルの列が揺れる。ユーザは「GDACS 専用テーブルに生の形で保存し、そこから `sea.hazard` に正規化する二層構造」を選び、この種の設計の定石を調査したうえで決めることを求めた。

空間列については、既存スキーマが PostGIS なし（lon / lat は `DOUBLE PRECISION`、polygon は GeoJSON `JSONB`）だったため、素の Postgres で足りるか、PostGIS か、専用の空間 DB かを空間 DB としての実力で比較した。ユーザは「PostGIS を PostgreSQL 18 相当で」と決めた。

制約は [[0002]] と同じで、判定ロジックは SQL ではなく Gleam に置く。正規化は純粋関数として単体テストでき、SQL は制約と CRUD だけを表現する。スキーマ変更は Atlas の versioned migration（[[0001]]）で行う。

## 決定

### 二層のテーブル

- **`sea.gdacs_event`（生の層）**: 主キー `(event_type, event_id, episode_id)`。GDACS の一覧 API が返す Feature のプロパティを型付き列に写し（alert level、severity の値・単位・文言、from / to / modified の時刻、`iscurrent`、centroid、bbox、影響国、各種 URL、GDACS 側の `source` / `sourceid`）、Feature 自体を `raw JSONB` に無加工で残す。episode は行として全部残す。`polygons/getgeometry` の FeatureCollection は `geometry JSONB` に、取得済みかどうかは `geometry_fetched_at` / `geometry_http_status` に持つ（`NULL` = 未取得、204 も「取得済み・形状なし」として記録）。
- **`sea.hazard`（正規化の層）**: 主キー `(source, source_id)`、`source` は `sea.source` への FK（[[0004]]）。GDACS では `source_id = "<event_type>-<event_id>"`（例 `EQ-1565193`）。イベントにつき 1 行で、常に最新 episode（`modified_at_ms` 最大、同値なら `episode_id` 最大）を反映し、`episode_count` を持つ。列は `hazard_type`（`earthquake | tropical_cyclone | flood | volcano | wildfire | drought | tsunami`）、`hazard_codes TEXT[]`、`glide`、`alert_level`（小文字）、`alert_score`、`cap_severity`、`severity_value / severity_unit / severity_label / estimate_type`、`title`、`description`、`countries TEXT[]`（ISO3）、`report_url`、`external_ids TEXT[]`、`onset_at / expires_at / modified_at`（TIMESTAMPTZ と `_ms` の対）、`is_current`、`centroid geometry(Point,4326)`、`bbox geometry(Polygon,4326)`、`primary_geometry geometry(Geometry,4326)`、`geometries JSONB`（最新 episode の FeatureCollection そのもの）。GiST index を `centroid` と `primary_geometry` に張る。

### 正規化は Gleam で、同一トランザクションで

生の行の upsert（SELECT 現在の revision → `intake/record.classify` → INSERT / UPDATE、[[0002]] と同じ型）と、影響を受けたイベントの `sea.hazard` 再計算を 1 つのトランザクションで行う。geometry が届いたときも同じ再計算を走らせる。正規化の規則はすべて `domain/hazard.gleam` の純粋関数にある。

- `hazard_type`: GDACS の `eventtype` 2 文字コードからの固定表。
- `hazard_codes`: IFRC GO Monty の慣例に倣い `glide:<code>`、`emdat:<slug>`、`undrr-isc-2025:<code>` を並べる。WF は Monty の表に UNDRR-ISC コードがないので省く。
- `cap_severity`: `green → minor`、`orange → severe`、`red → extreme`。Green → Minor だけが GDACS 自身の CAP 出力で確認でき、Orange / Red はこちらの決定である。
- severity: GDACS の `severitydata` を Monty の `severity_value / severity_unit / severity_label / estimate_type` の 4 つ組に写す。単位と文言が空で値が 0 のものは `NULL`。`estimate_type` は `primary` 固定。種別をまたいだ比較はしない。
- `external_ids`: GDACS 側の `source == "NEIC"` なら `usgs:<sourceid>`。
- `primary_geometry`: FeatureCollection のうち `Class == "Poly_Affected"` があればそれ、なければ `Poly_*` の Polygon / MultiPolygon で shoelace 面積が最大のもの。Point と LineString（サイクロンの track）は選ばない。
- `centroid` は Feature の Point、`bbox` は Feature の bbox（点に退化していれば `NULL`）。

SQL 側は `ST_SetSRID(ST_MakePoint(...), 4326)`、`ST_MakeEnvelope(..., 4326)`、`ST_SetSRID(ST_GeomFromGeoJSON($n::text), 4326)` で書き、`ST_X / ST_Y / ST_XMin ... / ST_AsGeoJSON(...)::text` で読む。pog に geometry 型の対応は足さない。`COALESCE` / `CASE` による判定は書かない。

### PostgreSQL 18 + PostGIS 3.6

- `db/Dockerfile` を `postgis/postgis:18-3.6` に替える。イメージ同梱の `/docker-entrypoint-initdb.d/10_postgis.sh` は `topology` / `tiger` / `tiger_data` スキーマと `template_postgis` を作り、Atlas が「clean でない DB」として `migrate apply` を拒むため、Dockerfile で削除する。拡張の作成は migration が唯一の経路になる。
- `CREATE EXTENSION IF NOT EXISTS postgis` は pg_trgm と同じ回避策で、migration `20260918110612_gdacs_hazards.sql` の先頭と `db/schema.sql` の両方に手書きする（Atlas Community Edition は拡張を管理できない）。
- `db/atlas.hcl` の dev database は `docker://postgis/18-3.6/dev`。ログインなしで `migrate diff` が通り、PostGIS 所有のオブジェクト（`spatial_ref_sys` 等）は両側に同じく存在するので `exclude` は不要だった。
- PostgreSQL 18 の公式イメージは `PGDATA` を `/var/lib/postgresql/18/docker` に、宣言 volume を `/var/lib/postgresql` に変えた。compose の `db` は `./db/data18:/var/lib/postgresql` をマウントし、Postgres 16 形式の `./db/data` は移行せずそのまま残す（各アダプタの起動時 backfill で埋め直す）。
- `db/scripts/test_core.sh`（`make test-core`）は `db/Dockerfile` をビルドした同じイメージで使い捨て DB を立てる。

### 公開 API と UI

- `GET /api/v1/hazards/recent?hours=&types=&levels=`（`{"hazards":[...],"count","generated_at"}`、ETag + `Cache-Control: no-cache`）、`GET /api/v1/hazards/stream`（SSE、`new` / `update` / `heartbeat` / `resync`、フィルタはクライアント側）、`GET /api/v1/hazards/{source}/{source_id}`（`geometries` と episode 履歴を含む詳細）。JSON の `id` は `"<source>:<source_id>"`。
- `/globe` に hazard レイヤ（alert level 色の点 + `primary_geometry` の面）と HazardPanel を足す。既定では `earthquake` を hazard レイヤから外す（canonical event の地震レイヤと二重描画になるため）。出典フッタは hazard の `source` も数え、GDACS の出典文言を常時表示する。

## 根拠（調査結果・出典）

- **二層パターン**: Databricks の medallion（bronze = 生・追記のみ・再生の真実、silver = 型付き・検証済み。「各タスクは冪等であるべき」）https://docs.databricks.com/aws/en/lakehouse/medallion 、dbt の staging（ソースと 1:1、型変換と改名のみ）→ intermediate → marts https://docs.getdbt.com/best-practices/how-we-structure/3-intermediate 。GDACS は 1 日数十件なので、生の insert と正規化の fan-out を同一トランザクションで行うのが最も単純で整合性の穴がない。
- **IFRC GO Montandon (Monty)**: モデル https://ifrcgo.org/monty-stac-extension/model/ 、GDACS のマッピング表 https://ifrcgo.org/monty-stac-extension/model/sources/GDACS/ 。item id は `eventid + episodeid`、「GDACS の event と episode は常に 1 つの hazard item を生む」、geometry は `getgeometry` の `Class == "Poly_Affected"` を選ぶ、`monty:hazard_detail` は `severity_value / severity_unit / severity_label / estimate_type`。種別 → コードの表（FL MH0600、EQ GH0101、TC MH0306、TS MH0705、VO GH0201、DR MH0401、EM-DAT slug `nat-geo-ear-gro` 等）は同ページから。`monty:corr_id` はソース横断の結合キーではない https://ifrcgo.org/monty-stac-extension/model/correlation_identifier/ 。Monty の実装 https://github.com/IFRCGo/pystac-monty は「`geteventdata` は `episodeid` を無視して現在の episode を返す」「TC の timeline は episode ごとに累積・重複する」と注意している。
- **UNDRR-ISC のコード揺れ**: 同じ Monty サイトの taxonomy ページ https://ifrcgo.org/monty-stac-extension/model/taxonomy/ は EQ を `GH0001`、TC を `MH0057` とし、GDACS ページの `GH0101` / `MH0306`（2025 年版の chapeau コード）と食い違う。単一のコードに正規化ロジックを吊るさず、版を接頭辞にした配列で持つ理由。
- **CAP 1.2**: severity の 5 段階（Extreme / Severe / Moderate / Minor / Unknown）https://docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html 。GDACS 自身の CAP 出力 `https://www.gdacs.org/contentdata/resources/EQ/1450385/cap_1450385.xml`（Green の M4.9）は `Severity=Minor`。Orange / Red の CAP ファイルは取得できず（404、ローテーション済み）、Orange → Severe、Red → Extreme はこちらの決定として Gleam の表に明示した。
- **GLIDE**: https://glidenumber.net/ 、https://www.emdat.be/sites/default/files/glide.pdf 。実測では中国の洪水（`FL-2026-000165-IND`）と Orange の地震には付いていたが、Red の M7.7（eventid 1558059）は 5 週間後も空だった。必須キーにしない。
- **EM-DAT 分類**: https://doc.emdat.be/docs/data-structure-and-content/disaster-classification-system/ 。
- **空間 DB の比較**: 現在のアクセスパターン（upsert、時間窓 + 種別 + level の一覧、GeoJSON を MapLibre に返す）は素の Postgres で足りる。将来の polygon 交差によるソース間照合、point-in-polygon、最近傍には PostGIS の `ST_Intersects` / `ST_Contains` / `<->` と GiST が要る。専用 DB は、MongoDB 2dsphere・Elasticsearch / OpenSearch `geo_shape`（`_mvt` API は優秀 https://www.elastic.co/blog/introducing-elasticsearch-vector-tile-search-api-for-geospatial ）・CrateDB・ClickHouse は年数千行の規模に対して運用コストが不釣り合い、DuckDB spatial は単一 writer モデル https://duckdb.org/docs/current/connect/concurrency 、SpatiaLite は 5.1.0（2023 年 8 月）から更新がなく https://www.gaia-gis.it/fossil/libspatialite/index 、Tile38 はリアルタイム geofence 向けで時系列クエリの形が合わない。MVT が要る段になれば PostGIS の上に Martin https://maplibre.org/martin/ を足す。
- **PostGIS と Atlas**: `postgis/postgis:18-3.6` は Docker Hub に存在（`docker manifest inspect` で確認）。Atlas の PostGIS FAQ https://atlasgo.io/faq/geometry-type は `CREATE EXTENSION postgis` をスキーマ SQL に直書きする手順を示し、拡張の HCL ブロックは Pro 限定 https://atlasgo.io/faq/postgres-extensions 。`geometry` を使う（`geography` ではなく）のは `ST_AsMVT` を含む大半の関数が geometry 前提のため。
- **PostgreSQL 18 イメージ**: `docker run --rm postgis/postgis:18-3.6 env` で `PGDATA=/var/lib/postgresql/18/docker`、`docker inspect` で宣言 volume が `/var/lib/postgresql` であることを確認した。
- **検証**: 使い捨てコンテナで migration 5 本（29 文）を先頭から適用し、`SELECT postgis_full_version()` → `POSTGIS="3.6.4" ... PGSQL="180"`、`atlas migrate status` → `Pending Files: 0`、`atlas schema diff --from <live> --to file://schema.sql` → `Schemas are synced`。`make test-core` は 125 テスト通過（純粋関数 + DB 統合）。再構築したスタックでは 14 日分の GDACS イベント（山火事 873、地震 192、洪水 54、サイクロン 16、干ばつ 14、火山 3）が `sea.gdacs_event` と `sea.hazard` に 1:1 で入り、地震の `primary_geometry` には ShakeMap 強度帯の MultiPolygon が選ばれ、詳細 API が FeatureCollection（12〜14 feature）と episode 一覧を返した。

## 検討した代替案

- **`sea.alert` を拡張して同居させる**: `source` 列を足して主キーを `(source, id)` にすれば CAP 的な形は流用できる。しかし NOAA の writer / reader / UI をすべて触ることになり、GDACS の alert level と種別別 severity は CAP の語彙に押し込むと情報が落ちる。NOAA が将来 `sea.hazard` に移る道は残っている。
- **GDACS 専用テーブルだけで正規化しない**: 最小工数だが、次のソース（各国 CAP、WIS2）が来たとき UI と API がソースごとの形を知る羽目になる。ユーザが二層を明示的に選んだ。
- **`sea.hazard` を episode 単位にする（Monty 方式）**: 1 episode = 1 item は履歴の表現としては素直だが、UI と API が「今のイベント」を出すたびに最新 episode を選び直す必要がある。履歴は生の層が全 episode を持つので、正規化の層はイベント単位で最新を写す。
- **素の Postgres で始めて PostGIS は後で**: 調査の推奨はこれだった（現在のアクセスパターンには十分で、GeoJSON JSONB を残しておけば後から `ST_GeomFromGeoJSON` で列を埋められる）。ユーザは将来の照合・point-in-polygon を見越して最初から PostGIS を選んだ。
- **専用の空間 DB**: 上記のとおり、どれもこの規模とアクセスパターンには過剰で、docker compose に状態を持つサービスが 1 つ増える。
- **PostgreSQL 16 のまま PostGIS だけ足す**: `postgis/postgis:16-3.5` で済み、データ移行も不要だった。ユーザは 18 相当を指定し、開発 DB のデータは backfill で埋め直せるので新規ディレクトリで起動した。
- **PostGIS の `geography` 型**: 長距離の距離計算はメートル精度で正確だが、本用途は交差・包含・描画が主で、`ST_AsMVT` 等の関数は geometry 前提。SRID 4326 の geometry を選んだ。

## 影響とトレードオフ

- **得るもの**: ソースに依らない hazard の表現、種別ごとの severity と CAP 互換の段階、polygon の保持、PostGIS による空間演算の余地。生の層は GDACS の Feature を無加工で持つので、正規化規則を変えても再取り込みなしで再計算できる。
- **データ移行をしなかった**: Postgres 16 の `./db/data` は放置し、18 は空から起動した。NOAA alert の履歴などは失われ、アダプタの backfill 範囲（USGS 7 日、EMSC 7 日、GDACS 14 日、NOAA active）だけが戻る。
- **Atlas と拡張**: `CREATE EXTENSION` は migration と `schema.sql` の二重管理のまま（pg_trgm と同じ）。イメージの initdb フックを消したので、PostGIS の topology / tiger 拡張が必要になったら migration で足す。
- **ソース間の hazard 照合は未実装**: hazard のソースは今のところ GDACS だけで、`(source, source_id)` の主キーと `external_ids` で結合の余地を作るに留めた。polygon 交差による照合と、それを受ける canonical 層（`sea.event` 相当）は 2 つ目の hazard ソースが来た時点で判断する。
- **`primary_geometry` の選び方は発見的**: EQ では `Poly_Affected` がなく、最大面積の `Poly_*`（強度 4 の帯）が選ばれる。TC の cone / track、FL の範囲で `Poly_Affected` が常にあるかは全種別で未確認。
- **`cap_severity` の Orange / Red は未確認の写像**、`hazard_codes` の UNDRR-ISC は版の揺れを含む、`glide` は空が多い。いずれも配列 / NULL 許容で持ち、下流で必須にしない。
- **`redistributable = false` の扱い**: GDACS の利用規約は免責のみで再配布条項がなく、RSS は public domain を掲げる。レジストリには保守的に `false` を入れたが、公開 API でこれを見て除外する処理はまだない（[[0004]] の宿題のまま）。
- **今後の課題**: 各国 CAP フィードを `sea.hazard` に載せるときの `cap_severity` 逆写像、hazard の viewport bbox フィルタ（`&&` と GiST）、MVT 配信（Martin）の要否。

## 関連ADR

- [[0001]] Atlas versioned migration。PostGIS 拡張と新テーブルはこの流儀で `20260918110612_gdacs_hazards.sql` に載せた。
- [[0002]] Gleam intake パイプライン。生の層の revision 判定は `Key("gdacs", "<type>-<id>-<episode>")` + `modified_at_ms` で同じ `classify` を使う。
- [[0003]] canonical event。GDACS の EQ は hazard とは別に地震パイプラインにも流れ、`external_ids` の USGS ID で結合する（[[0008]]）。
- [[0004]] ソースレジストリ。`gdacs` 行（priority 80、`redistributable = false`、出典文言）はここで宣言する。
- [[0005]] canonical API / UI。hazard の API と `/globe` のレイヤは同じ envelope / SSE の流儀に揃えた。
- [[0008]] GDACS アダプタ。この二層を埋める側。
