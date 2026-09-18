---
title: EMSC を push 型アダプタとして追加し FDSN で backfill と gap-fill を行う
status: accepted
date: 2026-09-18
depends-on: ["0002", "0006"]
---

# 0007: EMSC を push 型アダプタとして追加し FDSN で backfill と gap-fill を行う

## コンテキスト

`docs/internal/idea2.md` §7 は、全球イベント取り込みの着手順を「USGS・EMSC・GDACS から始め、正規化スキーマとソース間の重複排除を検証する」としている。USGS は既に取り込めており、クロスソース照合（[[0003]]）を実データで検証するには 2 つ目の地震ソースが要る。EMSC（Euro-Mediterranean Seismological Centre, seismicportal.eu）は USGS と観測対象が重なり、リアルタイム配信を無償で提供している。

これまでのアダプタ（NOAA、USGS）はすべてポーリング型で、条件付き GET と `Cache-Control` / `Expires` に従う周期取得だった。EMSC は WebSocket で push 配信する初めてのソースで、次の性質を調査で確認した（2026-09-18 時点）。

- WebSocket エンドポイントは `wss://www.seismicportal.eu/standing_order/websocket`。認証・サブプロトコル・Origin は不要。SockJS 版（`https://www.seismicportal.eu/standing_order`）もある。
- メッセージは `{"action":"create"|"update"|"delete","data":<GeoJSON Feature>}`。`data.id` は `properties.unid`（`YYYYMMDD_NNNNNNN`）と同じで、`lastupdate` はサーバ側が更新のたびに付け直す RFC3339（マイクロ秒精度）。`delete` も同じ形で届く。
- サーバは ping を送らない。EMSC 自身の Python 例は `ping_interval=15` でクライアントから ping する。JS / Python いずれの公式例にも再接続処理はなく、切断はログに出すだけで終わる。レート制限や同時接続数の制限は文書化されていない。
- 過去データは FDSN event サービス `https://www.seismicportal.eu/fdsnws/event/1/query` で取れる。`format=json` は EMSC 拡張で、WebSocket の `data` と同じプロパティ名の `FeatureCollection` を返す。実用上の最大 `limit` は 20,000、`orderby` は `time|time-asc|magnitude|magnitude-asc`、`updatedafter` で `lastupdate` による絞り込みができる。
- ライセンスは CC BY 4.0。出典表示は "Credit: EMSC/CSEM, https://www.emsc-csem.org"。非商用の再配布は可、商用は要許諾。

アダプタはプロセス内メモリしか持たず、再起動すると状態が消える。切断中に届いたイベントを取りこぼさずに、しかもコア側の重複排除（[[0002]]）に任せられる範囲で単純に作る必要があった。

## 決定

EMSC 専用の Go アダプタ `emsc_adapter` を追加し、WebSocket の購読を主経路、FDSN を補完経路とする。

- **ライブラリ**: `github.com/coder/websocket` v1.8.15。`Dial` / `Read` / `Ping` / `Close` が `context.Context` を取り、シャットダウン時のキャンセルが自然に書ける。
- **接続維持**: 15 秒ごとにクライアントから ping する。読み取りループは有界チャネルに `LiveMessage{Raw, LastUpdate}` を流し、バッチャが「100 件たまる」か「最初の 1 件から 500 ms 経つ」の早い方でコアに POST する。
- **起動時 backfill**: FDSN に `starttime = now-7d`, `endtime = now`, `orderby=time-asc`, `limit=20000` で問い合わせ、返却件数が `limit` に等しい間は `offset` を進めてページングする。`offset` は 1 始まりで送る。各ページを 1 バッチとして `backfill: true` で POST し、コアが受理するまで同じページを再試行する（`offset` は失敗時に進めない）。
- **再接続と gap-fill**: WebSocket のエラーや切断時は `poll.ComputeBackoff`（floor 5 秒、ceiling 10 分、ジッタ最大 5 秒）で再接続する。再接続に成功したら、受理済みバッチで見た最大の `lastupdate` から 5 分引いた時刻を `updatedafter` にして FDSN を 1 回引き、`backfill: true` で送ってからライブ購読に戻る。
- **コアへの契約**: 共通エンベロープ（[[0006]] の `core.PollMeta`）をそのまま使う。`features` は WebSocket と同じ `{"action","data"}` の配列で、FDSN の生 Feature は `{"action":"create","data":<feature>}` に包む。Feature の JSON は `json.RawMessage` として無加工で転送する。ライブバッチの `http_status` は 200、`feed_url` は WebSocket の URL、backfill は FDSN の応答ステータスとクエリ URL を入れる。`delete` はそのまま転送し、コア側が `status = "deleted"` に写す。ack は `core.ValidateAck` で検証する。
- **配信失敗**: コアへの POST が失敗したバッチは同じ内容・同じ順序でバックオフ再試行し、捨てない。読み取りループは有界チャネルで自然に詰まり、長時間の障害では WebSocket が切れて再接続後の gap-fill が取りこぼしを埋める。
- **コア側デコーダ**: `properties.unid` を `source_id`、`lastupdate` をミリ秒に切り詰めて revision、`auth` を `net` と `sources`、`source_id` を `code`、`flynn_region` を `place`、`evtype`（ISC の 2 文字コード）を USGS 風の `event_type` 語彙に写す（`ke|se|fe|de` → `earthquake`、`ls` → `landslide` など）。
- **設定**: `EMSC_CONTACT_EMAIL`（任意、User-Agent に載せる）、`EMSC_WEBSOCKET_URL` / `EMSC_FDSN_URL`（テスト用の上書き）、`EMSC_BACKFILL_DAYS`（既定 7）、`MATRIX_WHALE_URL`。compose に `emsc_adapter` サービスを追加し、CI マトリクスに `emsc_adapter/app` を加える。

## 根拠（調査結果・出典）

- WebSocket / SockJS のエンドポイント、メッセージ形式、公式例の ping と再接続の有無: https://www.seismicportal.eu/realtime.html 。ライブ接続で `101` の handshake を確認し、実メッセージ（`action: create`、`unid: 20260917_0000234`）を取得した。ping なしでも約 7 分は切断されなかったが、それ以上は未検証のため 15 秒 ping を採用した。
- FDSN のパラメータ、`format=json` 拡張、上限 20,000: https://www.seismicportal.eu/fdsn-wsevent.html 、https://www.seismicportal.eu/fdsnws/event/1/application.wadl 、https://www.seismicportal.eu/fdsnws/event/1/openapi.json 、基底仕様 https://fdsn.org/webservices/fdsnws-event-1.2.pdf 。
- `offset` は 1 始まり: 最初の統合実行で backfill が一度も届かず、ライブで `offset=0` を送ると HTTP 422 `{"detail":[{"type":"greater_than_equal","loc":["query","offset"],"msg":"Input should be greater than or equal to 1"}]}` が返ることを確認した。`offset` を省略するか `offset=1` にすると 200。修正はコミット 61c6ab4。
- 7 日分の実測: `limit=20000` で 2,413 件、約 1.3 MB、応答 2〜3 秒。1 ページで収まるが、ページングは `limit` 到達時のみ働くように実装した。
- `evtype` の語彙は ISC / IMS1.0 の 2 文字コード: https://www.isc.ac.uk/iscbulletin/search/catalogue/csvoutput/ 。FDSN の `eventtype` クエリパラメータ（QuakeML 語彙）とは別物である点に注意した。
- ライセンスと出典文言: https://www.seismicportal.eu/terms.html および realtime ページの "Data received via the websocket protocol is distributed under the CC BY 4.0 license"。
- Go の WebSocket ライブラリ: `coder/websocket` は旧 `nhooyr.io/websocket` の後継で継続的にリリースされている（https://pkg.go.dev/github.com/coder/websocket 、https://coder.com/blog/websocket ）。`gorilla/websocket` は 2022 年末にアーカイブされ 2023 年に再開されたが、その後約 2 年半タグが切られていない（https://github.com/gorilla/websocket 、https://github.com/orgs/gorilla/discussions/9 ）。`golang.org/x/net/websocket` は ping/pong と継続フレームの扱いが不完全で非推奨（https://github.com/golang/go/issues/33215 ）。
- 検証: `emsc_adapter/app` で `go vet ./...`、`go test -race ./...`（httptest と `websocket.Accept` による偽サーバで、ページング、422 相当の失敗時に `offset` を進めないこと、バッチの件数・時間フラッシュ、再接続後の `updatedafter` 付き gap-fill、配信失敗時の順序保持、graceful shutdown を検証）が通過。再構築したスタックで、backfill 1 回の POST（2,409 件）がコアに受理され、`/api/v1/pipeline/status` の `sources.emsc` は `received 2409 / written 2406 / deduped 3 / matched 447`。EMSC 行 2,408 件のうち 448 件が USGS のイベントに結び付いた（例: M6.5 Nikolski, Alaska、USGS `us7000ti1p` と EMSC `20260917_0000195`、misfit 0.13）。

## 検討した代替案

- **SockJS エンドポイントを使う**: EMSC の JS 例が使う経路で、SockJS が transport のハートビートを内蔵する。しかし Go 側に成熟した SockJS クライアントがなく、素の WebSocket で 15 秒 ping を打てば同等になる。
- **`gorilla/websocket`**: 最も知られたライブラリだが、リリースが 2024 年 6 月で止まり、未解決 issue が多い。長期稼働の購読者を新規に載せる先としては継続性が不安で、`context.Context` 対応も薄い。
- **`golang.org/x/net/websocket`**: 非推奨で ping/pong を正しく扱えないため除外。
- **WebSocket を使わず FDSN をポーリングする**: `updatedafter` を使えば差分取得はできるが、「秒〜分」層のソースをポーリングに落とすと遅延がポーリング間隔に縛られ、EMSC 側の負荷も増える。push が公式に提供されている以上、ポーリングは補完に留めた。
- **gap-fill を省く**: 再接続だけなら実装は簡単だが、切断中に配信されたイベントは FDSN から引き直さない限り欠落する。アダプタは状態を持たないので、`lastupdate` を基準にした 1 回の差分取得が最も安い保険になる。5 分の余裕は `lastupdate` の単調性が明文化されていないことへの手当て。
- **1 メッセージごとに POST する**: 実装は最も単純だが、地震の群発時にコアへのリクエストが連発する。100 件 / 500 ms のバッチャは遅延を 0.5 秒以内に抑えつつリクエスト数を減らす。
- **アダプタ側で `unid` の seen 管理を持つ**: 再起動で消えるうえ、コアの seen-set（[[0002]]）が同じ判定をするので二重になる。アダプタは無加工転送に徹した。

## 影響とトレードオフ

- **得るもの**: 2 つ目の地震ソースが入り、クロスソース照合（[[0003]]）を実データで検証できた。push 型アダプタの型（購読ループ、有界チャネル、バッチャ、再接続 + gap-fill）ができ、WIS2 の MQTT や MSC の AMQPS に転用できる。
- **未検証の前提**: 長時間（7 分超）の無通信時の切断挙動、レート制限、`unid` の安定性と `lastupdate` の単調性は EMSC の文書に明記がなく、観測と公式例の設計から推定している。削除されたイベントを FDSN がどう返すかも確認できていない（tombstone は無い前提）。
- **再起動コスト**: アダプタは状態を持たないため、再起動のたびに 7 日分（約 1.3 MB、2,400 件強）を backfill する。コアの seen-set と revision 判定で全件が `deduped` になるが、コアへの 1 回の大きな POST は発生する。これがコア側のトランザクション分割（[[0002]]）を必要にした。
- **`lastupdate` の丸め**: revision はミリ秒に切り詰めるため、同一ミリ秒内の 2 回の更新は区別できない。実用上は無視できる。
- **ライセンス**: CC BY 4.0 の出典表示義務は、ソースレジストリ（[[0004]]）と UI の常時表示（[[0005]]）で満たす。商用再配布は許諾が要る点はレジストリの `redistributable` では表現しきれておらず、必要になれば区分を分ける。
- **今後の課題**: 2 つ目の push 型アダプタが出た時点で、購読ループとバッチャを `adapters/common` に上げるかを判断する。EMSC の EventID サービスをライブで呼んで照合結果を突き合わせる検証は未実施。

## 関連ADR

- [[0002]] Gleam intake パイプライン。`unid` + `lastupdate` を source_id + revision として一段目の重複排除に載せ、backfill の大きなバッチはチャンク分割で受ける。
- [[0003]] canonical event。EMSC 行は USGS 行と misfit で照合され、同じ地震が 1 つの event にまとまる。
- [[0004]] ソースレジストリ。EMSC の CC BY 4.0 と出典文言、優先度 90 はここで宣言する。
- [[0005]] canonical API / UI。EMSC メンバーと出典が画面に出る。
- [[0006]] `adapters/common`。バックオフ、コアクライアント、ack 検証、ログ転送を共有する。
