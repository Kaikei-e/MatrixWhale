---
title: 警報は sea.alert を (source, source_id) 主キーの多ソース CAP 形テーブルに一般化し、NOAA も同じ表で扱う
status: accepted
date: 2026-09-19
depends-on: ["0001", "0002", "0004", "0010"]
---

# 0011: 警報は sea.alert を (source, source_id) 主キーの多ソース CAP 形テーブルに一般化し、NOAA も同じ表で扱う

## コンテキスト

`docs/internal/idea2.md` §7 の着手順 2 は「WMO の警報発表機関登録簿（RAA）から辿る各国の CAP フィード」で、既存の NWS 取り込みを全球に広げる位置付けである（取り込み経路そのものは [[0012]]）。受け皿の正規化テーブルを先に決める必要があった。

既存スキーマには各国 CAP をそのまま受ける場所がなかった。

- `sea.alert` は NOAA 専用で、主キーは NOAA の ID（`id TEXT`）だった。`source` 列がなく、UGC / SAME を専用の配列列で持ち、形状は GeoJSON の `JSONB`。
- [[0009]] は「NOAA は sea.alert に据え置き、各国 CAP は sea.hazard の 2 つ目のソースにする」道を想定していた。しかし `sea.hazard` は災害イベント単位の表で、`hazard_type` が 7 種の固定語彙、`alert_level` と `centroid` が NOT NULL である。CAP 警報は「地域 × 期間の発表」単位で、urgency / certainty / 複数の area / 言語違いの info を持ち、geocode しか持たない警報もある。
- `/api/v1/timeline`（[[0010]]）、Alerts タブ、SSE は alert の JSON 形をそのまま使っている。

ユーザは 3 案（`sea.alert` を多ソース化して NOAA も移す／`sea.hazard` に載せる／新しい正規化テーブルを作り NOAA は据え置く）から「`sea.alert` を多ソース化」を選んだ。あわせて「既存の NOAA 行は SQL で移行し、失効後 7 日の保持を NOAA にも適用」「Update / Cancel の連鎖は 1 通 1 行 + 置き換え印」「Alerts タブを全球化し地図に面を描く（CAP severity の 4 段階で色分け、既定は moderate 以上）」「形状が geocode だけの警報は一覧のみで地図に出さない」を決めた。判定ロジックは Gleam に置き、SQL は制約と CRUD に限る（[[0002]]）。スキーマ変更は Atlas の versioned migration で行う（[[0001]]）。

## 決定

### テーブル

`sea.alert` を次の形に作り替える。主キーは `(source, source_id)`、`source` は `sea.source` への FK（[[0004]]）。

- 識別: `source`, `source_id`（NOAA は従来の feature id、CAP は `<sender>,<identifier>`）, `sender`, `sender_name`, `identifier`, `message_type`（`Alert | Update`）。
- 内容: `event`, `category TEXT[]`, `severity`（`Extreme | Severe | Moderate | Minor | Unknown`）, `urgency`, `certainty`, `headline`, `description`, `instruction`, `web`, `contact`, `language`, `area_desc`, `geocodes JSONB`（`[{"name","value"}]`。NOAA の UGC / SAME もここに入る）, `countries TEXT[]`（ISO 3166-1 alpha-3）。
- 形状: `geom geometry(MultiPolygon, 4326)`（GiST index）。
- 時刻: `sent`, `effective`, `onset`, `expires`, `ends`, `active_until`（Gleam が決める有効期限、NOT NULL）, `first_seen_at`, `last_seen_at`。
- 終了: `ended_at`, `end_reason`（`expired | cancelled | superseded | withdrawn`）, `superseded_by`（新しい通の公開 ID）, `reference_keys TEXT[]`（`<sender>,<identifier>`、GIN index）。

### 移行（`db/migrations/20260919000000_multi_source_alerts.sql`）

- 先に NOAA の `sea.source` 行を `ON CONFLICT (id) DO NOTHING` で入れ、旧表を `alert_old` に改名、新表を作り、`INSERT … SELECT` で移し、旧表を落とす。1 ファイル・1 トランザクション。
- `geocodes` は `ugc` / `same` から組み立て、`countries = {USA}`、`language = 'en-US'`。形状は `jsonb_typeof = 'object'` のときだけ `ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(...), 4326)), 3))` に変換する。
- `active_until` は `ends → expires → sent + 24h → first_seen_at + 24h` の順で埋める。この一回限りの backfill だけは SQL の `COALESCE` / `CASE` を使う。既に終わった行は `end_reason = 'withdrawn'`。
- `db/schema.sql` は `sea.source` を最初に定義する順序に直し、`atlas migrate diff` が「差分なし」を返すことを確認した。

### 書き込みと失効

- **NOAA**: ポーリングのスナップショットに無い行を終える処理（→ `withdrawn`）、復活、`last_seen_at` の更新は、すべて `source = 'noaa'` に限る（多ソース化で CAP 行を巻き込まないため）。復活は `active_until > now` の行に限る。`active_until` は `ends → expires → sent + 24h → now + 24h` の順に Gleam で決める。
- **CAP**: `alert_writer.write_cap_rows` で挿入・更新と参照先の終了（`superseded` / `cancelled`）を同じトランザクションで行う。規則は [[0012]]。
- **既に期限切れの行**: `active_until <= now` の行は、最初から `ended_at = now`・`end_reason = 'expired'` で書き、SSE へは `alert.ended` として一度だけ流す。backfill で数千件の「新着 → 即終了」が流れるのを防ぐ。
- **失効**: `expire_due` を 60 秒ごとのジョブで独立したトランザクションとして走らせ、`active_until < now` の行を `expired` で終えて SSE に流す。NOAA の書き込み経路からは外した（NOAA に新着が無いと CAP が失効しなくなるため）。
- **保持**: 同じジョブで、全ソースについて `ended_at` から 7 日を過ぎた行を削除する。

### 公開 API と UI

- 公開 ID は `<source>:<source_id>` で、最初の `:` で分ける。CAP のソース ID は `cap-<oid>` とし、`:` を含めない。timeline のキーは `alert:<source>:<source_id>`。
- 一覧 / SSE / timeline の形状は `ST_AsGeoJSON(ST_Multi(ST_SimplifyPreserveTopology(geom, 0.01)), 4)` で返し、`description` と `instruction` は含めない。
- `GET /api/v1/alerts/detail?id=` は、全精度の形状（`ST_AsGeoJSON(geom, 6)`）、本文、CAP の全 info、`cap_url` / `feed_url` を返す。
- `/api/v1/alerts/active` に `sources` / `countries` / `min_severity` のフィルタを足した。`/api/v1/sources` は DB の `sea.source` 全行を返す。
- SSE は `alert.new` / `alert.update` / `alert.ended` を、アラートの JSON そのままで流す。イベント ID の起点を起動時刻（ミリ秒）にし、`Last-Event-ID` がリングより古いか、現在より新しい（再起動前の）ときは `resync` を送る。
- Web の変更点:
  - Alerts タブを全球化し、severity のチップ（既定は Extreme / Severe / Moderate）と国セレクタを付けた。
  - 地図の面、NOAA のゾーン、中心点のマーカー、一覧の色点を同じ 5 段階の色でそろえた。
  - 詳細は `/alerts/detail` を遅延取得する。取得は id と `last_seen_at` をキーにキャッシュし、上限を設けた。
  - 出典には機関名を 3 件まで出し、残りは「+N more」にまとめる。
  - NOAA のゾーンは `geocodes` の UGC から引く。

## 根拠（調査結果・出典）

- **CAP 1.2**（https://docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html ）
  - `identifier` は sender ごとに一意で、空白やカンマを含まない。そのため `<sender>,<identifier>` は一意なキーになり、`references`（`sender,identifier,sent` の空白区切り）とも直接突き合わせられる。
  - `info` の `language` が無いときの既定値は `en-US`。
  - `severity` / `urgency` / `certainty` は列挙語彙である。
- **移行の検証**:
  - 実 DB の `pg_dump` を使い捨てコンテナに復元して migration を当てた。1,387 行（有効 398、形状あり 567）がすべて移り、形状が空になった行は 0、989 行が `withdrawn` になった。
  - その後、実 DB 自体にも適用した（27 文、0.1 秒）。適用前の dump は退避してある。
- **形状の型の実測**:
  - `ST_SimplifyPreserveTopology` は部品 1 つの MultiPolygon を POLYGON に落とす（NOAA 604 行、CAP 99 行）。そのため一覧側で `ST_Multi` を掛けた。以後は 715 行すべて MULTIPOLYGON で返る。
  - CAP の最大 polygon は 55,542 点あり、簡略化しないと一覧 API が肥大する。
- **テスト**:
  - `make test-core` で 257 件が通った。NOAA の終了処理・復活・`last_seen_at` 更新が CAP 行に触れないこと、期限切れの挿入、`expire_due`、形状の往復、`,` や `@` を含む ID での timeline のページング、`min_severity` の検証を含む。
  - 実スタックでの受け入れスクリプトも全項目が通った。見た内容は、ソースごとの ack の整合、一覧の形状がすべて MultiPolygon か null であること、詳細 API、`active_until` を過ぎた有効行が 0 であること、SSE の heartbeat と整数 ID、timeline。
  - Web は vitest と Playwright で検証した。

## 検討した代替案

- **CAP を `sea.hazard` に載せる（[[0009]] の想定）**
  - `hazard_type` の固定語彙、`alert_level` / `centroid` が NOT NULL であることと合わない。
  - urgency / certainty / 複数の area / 言語違いの info が落ちる。
  - geocode しか持たない警報は centroid を作れない。
- **新しい正規化テーブル（例: `sea.warning`）を作り NOAA は据え置く**
  - 改修量は最小になる。
  - しかし Alerts タブ、timeline、SSE、検索がそれぞれ 2 表を読むことになり、警報という同じ概念が二重化する。
- **Update / Cancel の連鎖を 1 行にまとめる（GDACS の event / episode と同型）**
  - UI の重複は消える。
  - しかし元の通を取りこぼしたときや、複数の通を参照するときに、連鎖の根が定まらない。1 通 1 行にし、参照された行へ終了の印を付ける方式にした。
- **形状を `JSONB` のまま持つ（旧 NOAA と同じ）**
  - [[0009]] で PostGIS を採った流れと食い違う。
  - `ST_MakeValid` や簡略化などの空間演算の土台も失う。
- **NOAA 行を捨てて再取得する**
  - NWS API は現在有効な警報しか返さないので、過去の履歴が消える。SQL で移すほうを選んだ。
- **一覧に全精度の形状を載せる**
  - 5 万点級の polygon を含むと、一覧 API と SSE が肥大する。約 1 km（0.01°）に簡略化し、全精度は詳細 API で返すことにした。
- **SSE の ID をプロセス内カウンタのままにする**
  - 再起動すると ID が 1 に戻り、再接続したクライアントに無関係なイベントを再送してしまう。起動時刻（ミリ秒）を起点にした。

## 影響とトレードオフ

- **得るもの**: NOAA と各国 CAP が同じ表・同じ API・同じ UI に乗った。timeline の alert 種別もそのまま全球化した。失効と保持の規則が全ソースで一つになった。
- **NOAA の JSON 形の変更**:
  - `ugc` / `same` は `geocodes` に移り、`id` は `noaa:<feature id>` になった。
  - このためブラウザに保存された確認済み ID は一度無効になる。
- **移行した NOAA 行の本文**: `description` や `sender` は NULL のまま移っており、NWS が再発表したときに埋まる。有効期間の中で自然に解消する。
- **CAP の expires 欠落**: `expires` の無い CAP は `sent + 24h` まで有効とみなす。実際の失効より早いことも遅いこともある。
- **地図に出ない警報**:
  - geocode だけの警報（MeteoAlarm の EMMA_ID / NUTS3、BoM の AMOC）は一覧にだけ出る。
  - `ST_MakeValid` の結果が空になった形状は `coordinates: []` になり、Web はこれを描かない。
- **SSE の ID の重なり**: 1 回の稼働でミリ秒数より多いイベントを出した直後に再起動すると、ID が重なりうる。実害が小さいので受け入れた。
- **今後の課題**:
  - geocode から形状を引く仕組み（MeteoAlarm の境界 GeoJSON など）。
  - NOAA と各国 CAP、hazard と alert のあいだの照合。
  - `redistributable = false` の機関を API で実際に除外するかの判断（[[0004]]）。

## 関連ADR

- [[0001]] Atlas の versioned migration。手書きの移行 SQL と `atlas.sum` の再ハッシュ。
- [[0002]] 判定は Gleam、SQL は制約と CRUD。移行の backfill だけを例外にした。
- [[0004]] ソースレジストリ。`sea.source` は DB から読むようにし、CAP の機関ごとに行を持つ。
- [[0009]] ここで想定していた「各国 CAP を sea.hazard に載せる」案は採らなかった。
- [[0010]] timeline の alert キーと payload は新しい形に変わった。
- [[0012]] 各国 CAP フィードの取り込みと、正規化の規則。
