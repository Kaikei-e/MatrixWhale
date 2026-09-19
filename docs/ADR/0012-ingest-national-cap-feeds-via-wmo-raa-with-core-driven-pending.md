---
title: WMO RAA から辿る各国 CAP フィードを cap_adapter で巡回し、CAP 本体の取得判断はコアの pending で駆動する
status: accepted
date: 2026-09-19
depends-on: ["0002", "0004", "0006", "0011"]
---

# 0012: WMO RAA から辿る各国 CAP フィードを cap_adapter で巡回し、CAP 本体の取得判断はコアの pending で駆動する

## コンテキスト

`docs/internal/idea2.md` §7 の着手順 2 は、WMO の警報発表機関登録簿（Register of Alerting Authorities, RAA）から各国の CAP 警報フィードを辿って取り込むことである。正規化先は [[0011]] で多ソース化した `sea.alert` に決まっている。2026-09-19 に公開面を実測した結果は次のとおり。

- **RAA 本体**: 登録簿は `https://alertingauthority.wmo.int/rss.xml` で公開されている。idea2.md は Atom と書いていたが、実際は **RSS 2.0** だった。303 件の `<item>` があり、各 item は `iso:countrycode`（ISO3）、`guid`（`urn:oid:…`）、`raa:capAlertFeed`（`xml:lang` 付き、0 本以上）、`raa:authorityAbbrev` を持つ。`author` は個人のメールアドレスなので保存しない。
- **フィード URL**: フィードを持つ機関は 159、URL は 221 本（重複を除いて 194〜195 本）、国は 130。同じ URL を複数の機関が載せている例がある（カナダの NAAD ×4、FMI ×3）。
- **疎通**: 221 本のうち 199 本が 200 を返した。形式は RSS 128、Atom 61、HTML 7、JSON 2。残りは 404 か、タイムアウト / DNS / TLS の失敗だった。ETag を返すのは 100 本、Last-Modified を返すのは 143 本。
- **索引の中身**: 索引の項目は合計 4,854 件。66 本は空だった。1 年分の履歴を残すフィードもある（トリニダード・トバゴは 845 件）。どのフィードも「索引 → 各項目の CAP XML へのリンク」の二段構成で、MeteoAlarm は `type="application/cap+xml"` のリンクを別に持つ。
- **CAP 本体の標本**: フィードごとに 1 通、計 107 通を取った。
  - すべて CAP 1.2 だった。
  - 形状は polygon 87、circle のみ 9、geocode のみ 10。
  - 複数言語の info を持つものが 24、XML 署名付きが 28。
  - 最大の polygon は 55,542 点。
- **ホストの集中**: `cap-sources.s3.amazonaws.com` に 64 本、`feeds.meteoalarm.org` に 34 本が集まっている。

ユーザと決めたこと:

- XML は Go アダプタで JSON に写し、判断はしない。
- RAA の全フィードを自動で使う。ただし NWS は `noaa_adapter` と重なるので除く。
- 全 info を保持し、英語を優先して表示する。英語フィードがある機関では、英語以外のフィードを購読しない。
- どの CAP 本体を取りに行くかはコアが pending で返す（[[0008]] の geometry と同型）。
- ポーリングは 5 分間隔。
- 機関ごとに `sea.source` 行を持つ。
- 正規化するのは Actual かつ Public の通だけ。
- フィードの健全性を DB・API・`/feeds` 画面で見せる。

## 決定

### Go アダプタ `cap_adapter`

`cap_adapter/app` に置き、`compose` の `10.254.100.45` で動かす。`adapters/common` を使い（[[0006]]）、`PollMeta` に `error` / `format` を追加した。

- **RAA**: 起動時と 24 時間ごとに条件付き GET で取得し、`POST /cap_data/registry` で全 item を送る。ETag と取得時刻は、POST が成功したときだけ更新する（失敗したら次の周期で再送する）。
- **フィードの巡回**: 5 分周期で `GET /cap_data/feeds` を読み、期限の来たフィードを条件付き GET で取得して、`POST /cap_data/index` を 1 本ごとに送る（失敗時も送る）。
  - 取得後に本文の読み取りや解析に失敗したときは、`http_status: 0` と `error` を付けて送る。
  - フィードの validator も、index の POST が成功したときだけ更新する。
  - RSS 2.0 / RSS 1.0（RDF）/ Atom を扱う。`<link>` と `<title>` は、項目要素と同じ名前空間か、名前空間なしのものだけを採る。
  - `cap_url` は、`application/cap+xml` のリンクを優先して取り出し、相対 URL は解決する。
- **CAP 本体の取得**: フィード巡回には周期の 60% の締め切りを設ける。残りの時間で `GET /cap_data/pending?limit=50` を読んで取得し、`POST /cap_data/alerts` を 10 件または 16 MiB ごとに送る。
  - POST が失敗したら、その周期の取得を止める。
  - XML はまず厳格モードで解析し、構文エラーのときだけ寛容モードで読み直す（HTML の実体参照を許す）。
  - CAP 1.0 / 1.1 / 1.2 と名前空間なしを受け付ける。
  - `raw_xml` は UTF-8 に変換し、宣言の encoding を書き換える。NUL を除き、ルート要素の終わりより後ろは切る。
  - `Signature` と `derefUri` は落とす。
- **行儀**:
  - 同じホストには同時に 1 本まで、前の本文を読み終えてから 2 秒空ける。
  - 並行するホストは最大 8。
  - タイムアウトは 30 秒、本文の上限は 8 MiB。
  - 環境変数で調整できる。

### コア（判断はすべて Gleam の純粋関数）

- **登録簿**（`domain/raa.gleam`）:
  - 機関ごとにソース `cap-<oid>` を作る。priority 70、`redistributable = false`、出典は「機関名 (国名), via the WMO Register of Alerting Authorities」。
  - フィードの持ち主は、RAA の文書順で最初に載せた機関とする。
  - 除外の理由は `nws` / `language` / `removed`。除外は、その URL を載せている全機関が除外するときに限る。
  - 機関を 0 件しか解析できないとき、または既知の機関の半数を超えて「削除」にするときは、その POST を 422 で拒否する。
  - 同じ oid が重複したら最初の 1 件だけを採る。
- **索引**（`domain/cap.gleam`）:
  - 新しい項目は pending にする。ただし公開日時が 7 日より古いものは skipped にして取りに行かない。
  - 取得結果の扱い:
    - 404 / 410 / 429 以外の 4xx と、CAP でない文書 → 恒久的な失敗。
    - 429 / 5xx / 0 → 3 回まで、15 分空けて再試行。
    - DB 書き込みの失敗 → 実際の HTTP ステータスのまま、再試行可能として記録する。
- **健全性**:
  - 判定は excluded → pending → failing（連続失敗 3 回以上）→ degraded → stale（最新項目が 30 日より古い）→ empty → ok の順。
  - 連続失敗の回数でポーリング間隔を 300 / 3,600 / 21,600 秒に延ばす。
- **メッセージ**（`repository/cap_message_writer.gleam`）:
  - 1 通ごとに 1 トランザクションで処理する。
  - `(sender, identifier)` と `sent` で重複と改訂を判定する。
  - 最初に届けたフィードの機関がソースと国を持ち続ける。
  - 書き込みに失敗した通は seen-set に入れない（`pipeline.run` の `WrittenExcept`）。seen-set で重複と判定された通も、その項目は fetched にする。
- **正規化**:
  - 対象は Actual かつ Public の Alert / Update だけ。
  - 表示言語は、最初の `en*` の info の言語。無ければ最初の info の言語。
  - 表示言語と同じ言語の info の中で severity が最大のものを採る（同点は先のもの）。
  - area は、表示言語の info すべての area をまとめる。
  - polygon は `lat,lon` の並びで、閉じていなければ閉じ、4 点未満の輪は捨てる。
  - circle は 32 角形で近似する。
  - 経度の幅が 180° を超える輪は、負の経度に 360 を足す。
  - `5e-06` のような指数表記も受け付ける。
  - `active_until` は expires、無ければ sent + 24h。
  - 生の通の保持期限 `expires_at` は、全 info の expires の最大と sent + 24h の大きいほう。
- **置き換えと取り消し**:
  - Actual の Update は参照先を `superseded` にし、Actual の Cancel は参照先を `cancelled` にする。
  - 順序が逆転して届いた場合は、先に来た通が正規化済みの Public かつ Actual のときだけ、後から来た通を終了済みとして挿入する。
  - 正規化できなくなった新しい改訂が来たら、古い行を `withdrawn` にする。
- **公開**:
  - `GET /api/v1/cap/feeds` は、フィードごとの健全性、機関、件数、有効な警報数、失敗した項目数を返す。
  - `/api/v1/pipeline/status` に `cap` を加えた。
  - Web に `/feeds`（健全性のチップ、検索、並べ替え）を加えた。

## 根拠（調査結果・出典）

- **一次情報**:
  - RAA https://alertingauthority.wmo.int/rss.xml と https://alertingauthority.wmo.int/ 。登録簿そのものは「警報は含まず、各機関の公式な発表元への索引である」と明記している。
  - CAP 1.2 https://docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html 。`references` の書式、`status` / `scope` / `msgType` の語彙、`info` の言語の既定値の根拠。
- **実データでのハーネス**: 取得した 221 本の索引、102 通の CAP、RAA 本体を、実装したパーサとコアのデコーダに通した。
  - 190 本を解析できた。解析できなかったのは空 22、HTML 7、JSON 2 で、いずれも「not an XML feed」として報告される。
  - 4,870 件の項目すべてに `cap_url` が付いた。
  - CAP は 102 通すべてを解析でき、コアに拒否された通は 0、UTF-8 として不正な `raw_xml` も 0 だった。
- **負荷試験**（`-race` 付き）:
  - 130 ホスト・226 本のフィードで、競合は無し、ホストごとの同時接続は常に 1 以下、goroutine はすべて戻った。
  - 遅いホストがあってもフィード巡回の締め切りが効き、CAP 本体の取得が毎周期走った。
- **実スタックでの結果**（約 1 時間）:
  - 機関 303、フィード 195（購読 148、除外 47 のうち `nws` 2・`language` 45）。
  - 健全性は ok 67、empty 38、stale 22、failing 21。
  - 索引の項目は 3,407。うち 1,518 は 7 日より古いので skipped。
  - 通は 390 で、うち 376 を正規化した。有効な CAP 警報は 229（15 か国）。
  - 置き換え 2、取り消し 6。Test 状態の通 3 と Cancel 11 は正規化していない。失敗した項目は 0。
  - 受け入れスクリプトは全項目が通った。
- **テスト**:
  - Go: テスト関数 45（`-race` で 2 回ずつ）。
  - Gleam: `make test-core` 257 件。同じバッチ内での Alert + Update / Cancel の両順序、Test 状態の Cancel、seen-set の重複、書き込み途中の失敗（NUL を含む `raw_xml`）、先着のフィードが勝つこと、登録簿の拒否、ack の整合を含む。
  - Web: vitest と Playwright。

## 検討した代替案

- **CAP XML を Gleam で解析する（xmerl FFI）**: アダプタが raw forwarder であることに最も忠実だが、Gleam 側に XML の FFI と名前空間の処理を書くことになる。「判断をしない変換」はアダプタに置いてよいとした（ユーザの選択）。
- **取得済みかどうかをアダプタのメモリやディスクで覚える**: 再起動のたびに約 4,850 件を取り直すか、アダプタに状態を持たせることになる。コアが pending を返せば再起動に強く、判断もコアに残る（[[0008]]）。
- **許可リストで少数のフィードから始める**: 品質は揃うが、登録簿を辿る意味が薄れる。全件を使い、健全性で監視することにした（ユーザの選択）。
- **全言語のフィードを購読する**: DWD の de / en やロシアの ru / en のように、別 identifier の同内容の警報が並んでしまう。
- **毎周期すべての CAP を取得する**: 5 分ごとに約 4,850 リクエストになり、小国のサーバへの負荷として許容できない。
- **単一ソース `wmo_raa` / 国ごとのソース**: 出典表記が不正確になるか、同じ国の気象庁と防災庁が混ざる。
- **バッチ全体を 1 トランザクションで処理する**: 最初の実装はこれだった。しかし 1 通の不正でバッチ全体が止まり、その項目が永久に pending のまま残ることがレビューで分かり、1 通ごとに分けた。
- **最初から寛容モードで XML を解析する**: HTML の自動終了で `<info>` が途中で閉じ、area が黙って消えうる。厳格モードを先に試すことにした。
- **登録簿の POST を無条件に受け入れる**: RAA が空や途中切れの応答を返すと、全フィードの購読が外れてしまう。

## 影響とトレードオフ

- **得るもの**: 130 か国の公式な警報発表元が、NOAA と同じ表・API・地図に乗った。各フィードの状態は `/feeds` で一覧できる。
- **初回 backfill は遅い**: ホストごとに 2 秒空ける制約で、実測は毎秒 0.5 通前後だった。初回の約 1,900 通が揃うまで 1 時間程度かかる。`CAP_HOST_MIN_INTERVAL` と `CAP_MAX_PARALLEL_HOSTS` で調整できる。
- **RAA のデータ品質に依存する**:
  - `xml:lang` の誤りがある。ベラルーシの英語フィード（`…/cap-feed/en/atom.xml`）が `ru` と表記されており、除外されている。
  - HTML のページを指すリンクがある（InaTEWS、USGS のイベントページ、hochwasserzentralen のポータル）。これらは恒久的な失敗として記録される。
  - stale 22 本、failing 21 本は、発表元の問題である。
- **地図**: geocode だけの警報は地図に出ない（[[0011]]）。
- **ライセンス**: 登録簿にライセンス情報が無いので、全機関を `redistributable = false` にした。API での除外はまだ行っていない（[[0004]]）。
- **ソース間の照合はしない**: MeteoAlarm と各国の直接フィードの重複は、`(sender, identifier)` が同じ場合にだけ一つにまとまる。
- **メモリ**: 8 MiB の文書が並ぶと、アダプタは最悪 2 GB 程度を使う（compose にメモリ上限は付けていない）。
- **User-Agent**: `CAP_CONTACT_EMAIL` が未設定なので、連絡先の無い User-Agent で巡回している。
- **今後の課題**:
  - geocode から形状を引く仕組み（MeteoAlarm の EMMA_ID の境界など）。
  - ソースをまたいだ警報の照合。
  - 機関ごとのライセンス。
  - 健全性の悪化を通知する仕組み。
  - 大きなホスト（S3）で並列度を上げること。
  - 次の着手対象である WIS2。

## 関連ADR

- [[0002]] 取り込みの重複排除（seen-set と revision の判定）。CAP の通は `Key("cap", <sender>,<identifier>)` と `sent` で扱う。
- [[0004]] ソースレジストリ。機関ごとの `cap-<oid>` 行と出典文言。
- [[0006]] `adapters/common` を共有し、`PollMeta` に `error` / `format` を追加した。
- [[0008]] コアが返す pending で取得を駆動する方式を、geometry から CAP 本体に広げた。
- [[0011]] 正規化先の多ソース `sea.alert`。
