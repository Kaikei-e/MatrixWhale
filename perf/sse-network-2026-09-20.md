# SSEと低速回線の計測（2026-09-20）

## HARの分析

入力はユーザー提供の `localhost.har`（13,245,732 B）。JSONを一度読み、本文を出力せずメタデータとSSEイベント名を集約した。47リクエスト、転送量合計5,034,672 B。

| 対象 | 転送量 | イベント |
| --- | ---: | --- |
| hazards SSE | 1,961,949 B | update 74、new 1、heartbeat 3 |
| earthquakes SSE | 296 B | heartbeat 3 |
| alerts SSE | 3,216 B | alert.new 1、alert.ended 1、heartbeat 3 |

SSEの約44秒は観測中の接続時間であり、有限レスポンスの完了時間として扱わない。hazards SSEだけで全転送量の39.0%を占める。SSE本文はHARに保存されていないため、元の75件について個別のgeometryサイズを推測していない。

| 地図ファイル | blocked | サーバーへの送信後のwait | receive |
| --- | ---: | ---: | ---: |
| land-coast | 16,443 ms | 157 ms | 70 ms |
| nws-forecast-zones | 16,444 ms | 224 ms | 558 ms |
| nws-counties | 15,024 ms | 148 ms | 119 ms |
| nws-marine-offshore-zones | 19,469 ms | 693 ms | 139 ms |

いずれもpriorityはLow。`_blocked_queueing`はblockedのほぼ全量を占める。APIの処理時間と、ブラウザーが送信を保留する時間を区別した。

## 固定データによる対照実験

Chromium 153.0.8010.12、HTTP/1.1、下り200,000 B/s、上り93,750 B/s、遅延150 ms。同一100,000 Bファイル2件を `priority: low` で取得する。SSEは初回heartbeatだけを送って接続を保持する。

最初は回線品質判定を固定せずに試し、3本でも1本でも約1.155秒で完了した。次にChromiumのネットワーク品質推定を `--force-effective-connection-type=3G` で固定すると、3本・1本・3本・1本の順で次の結果を得た。

| SSE接続数 | 1回目の送信前待機 | 2回目の送信前待機 | 2ファイルの完了時間 |
| --- | ---: | ---: | --- |
| 3本 | 15,011 ms | 15,014 ms | 16.165 / 16.172 s |
| 1本 | 0.6 ms | 0.6 ms | 1.155 / 1.155 s |

ライブイベントの量と無関係に、低速回線判定と3本のSSEでHARの約15秒待機を再現した。Chromiumの[スケジューラー実装](https://chromium.googlesource.com/chromium/src/+/HEAD/services/network/resource_scheduler/resource_scheduler.cc)と[回線品質別の設定](https://chromium.googlesource.com/chromium/src/+/HEAD/services/network/resource_scheduler/resource_scheduler_params_manager.cc)では、3G以下の高優先度要求の重みが3、待機判定の上限が8となっている。3本のSSEで重み9となり、空きソケットがあっても低優先度要求が保留される。

HARには回線品質推定値がないので、ユーザーのブラウザー内部値そのものを確認したという意味ではない。CDPの帯域制限によってページ側の `navigator.connection.effectiveType` は4gと表示されるため、対照実験の条件はこの値でなくネットワークプロセスへの起動引数で記録した。

結果: `results/slow-network/sse-scheduling.json`、`results/slow-network/sse-scheduling-3g.json`。

## 実装

- `/api/v1/stream?geometry=polyline` で警報・地震・災害のSSEを共有し、ページ内では1本だけ接続する。
- 災害のポリゴンを既存の可逆polyline形式で配信する。座標の丸めや頂点の削除は行わない。ブラウザーで復元してから地図・Timelineへ渡す。
- 同じ表現の符号化を購読者ごとに繰り返さず、購読者がいない表現は生成しない。
- 3つのhubへの登録を完了してからHTTPヘッダーを送る。共有接続の再開時に一覧を再取得し、再同期通知との重複取得を抑える。
- 既存の個別SSEと通常GeoJSON形式を維持し、単一Last-Event-IDを別のhubに流用しない。
- 接続終了時は購読と中継プロセスを解放する。MistはSSEのcloseコールバックを持たないため、送信失敗とSSEプロセス監視で処理する。
- 大きい地図ファイルは一覧取得の完了を待ってから最大2本ずつ取得する。APIの失敗・長時間停滞に備え、待機は15秒で打ち切る。

設計判断は [ADR 0014](../docs/ADR/0014-share-sse-connection-and-encode-hazard-geometry.md) に記録した。

## 同一イベントの転送量と完全復元

稼働中のPlecto経由で旧 `/api/v1/hazards/stream` と新 `/api/v1/stream?geometry=polyline` を同時に購読し、hubのイベントIDが一致するものだけを比較した。DBへのイベント投入は行っていない。

最初の90秒は6件（本文26,922 → 10,505 B）だったため、続けて180秒観測し、HARの転送量に近い66件を取得した。

| 指標（同じ66イベント） | 旧形式 | 可逆符号化 |
| --- | ---: | ---: |
| JSON本文 | 1,945,224 B | 473,552 B |
| SSEのid・event・data行を含むフレーム | 1,949,181 B | 478,037 B |
| 初回イベント受信（接続開始から） | 23.62 ms | 23.93 ms |

本文は75.7%、SSEフレームは75.5%減った。66件中52件でgeometryが符号化された。66件すべてで実際のGleam配信をブラウザーと共通のTypeScriptデコーダーに通し、座標を含む全フィールドの完全一致を確認した。

新接続全体の501,360 Bには警報・地震・heartbeatも含まれるため、旧hazards接続全体と単純に比較しない。上表は同じ災害イベントに限定している。結果は `results/slow-network/sse-matched.json` と `sse-matched-long.json`。

実HTTPで初回3チャネルのheartbeat、`Last-Event-ID`付き再接続の3チャネルresync、Content-Type、非バッファリングヘッダーも確認した。

## 実画面の変更前後

`http://localhost:8180/globe` を新しいブラウザーコンテキストで開き、キャッシュを消して60秒観測した。Chromium 153.0.8010.12、下り1.6 Mbps、上り750 Kbps、遅延150 ms、ネットワークプロセスの回線判定3Gで統一した。変更前・共有SSEと符号化のみ・一覧取得を優先する最終版の各1回の測定である。

| 指標 | 変更前 | 共有SSE・符号化 | 最終版（一覧を優先） |
| --- | ---: | ---: | ---: |
| SSE接続数 | 3 | 1 | 1 |
| 全地図データの取得完了 | 57.119 s | 18.093 s | 18.330 s |
| Timeline初回件数表示 | 1.568 s | 1.568 s | 1.469 s |
| 地震の初回件数表示 | 2.518 s | 2.069 s | 2.069 s |
| 警報の初回件数表示 | 8.870 s | 9.668 s | 9.615 s |
| 災害の初回件数表示 | 11.713 s | 15.794 s | 11.448 s |
| FCP | 1.136 s | 1.108 s | 1.028 s |
| LCP | 2.524 s | 2.072 s | 2.036 s |
| 有限レスポンスの転送量 | 3,289,701 B | 3,298,488 B | 3,293,643 B |
| 観測中のSSE転送量 | 730,184 B | 9,779 B | 3,368 B |
| 通信失敗・HTTPエラー・画面例外 | 0 | 0 | 0 |

全地図データの取得完了は38.789秒（67.9%）早まった。地図ファイル6件の内容と転送サイズは3回とも同じで、各ファイルの取得は1回ずつだった。共有SSEだけでは地図転送と災害一覧の帯域競合が生じたため、最終版では一覧の取得後に大きい地図ファイルを開始する。最終版の最初の大きい地図リクエストは11.294秒、全地図データの完了は18.330秒だった。

これは稼働中データでの各1回の実測であり、観測時刻によって一覧・イベント数が異なる。特にSSE総転送量の差を実装の削減率とは扱わない。削減率は前節の同一イベント比較、約15秒の待機の原因は固定データの対照実験で評価する。警報の初回件数表示は変更前より0.746秒遅く、全指標が改善したという結果ではない。地図の完了時間はネットワーク取得完了を表し、描画完了ではない。タブの件数は100 ms間隔で観測している。

測定結果は `results/slow-network/sse-before-3g.json`（04:37 JST）、`sse-after-3g.json`（04:57 JST）、`sse-after-final-3g.json`（09:35 JST）に保存した。

## 検証と反映

- `pnpm check`: 型・Svelte診断ともにエラー0、警告0。
- フロントエンド単体テスト: 28ファイル、332件成功。
- `make test-core`: 一時PostgreSQLでの結合テストを含む309件成功。バックエンドの最終修正後の `gleam test` も309件成功。
- Playwright: network・globe・alerts・timelineの25件成功。共有接続、地図の重複取得、再同期・更新表示を検証した。
- ADR検証: 14文書、30依存関係の検証成功。対象変更の `git diff --check` 成功。
- バックエンドとWebのDockerビルド成功。ローカルComposeの両サービスに反映済みで、最終計測は反映後のWebイメージ `5bcf756a7513` に対して行った。

## 再現コマンド

`web/app` から実行する。結果にはレスポンス本文を含めず、集計値とタイミングを保存する。

```sh
node scripts/perf/har.mjs ../../localhost.har
node scripts/perf/sse-scheduling.mjs --out ../../perf/results/slow-network/scheduling.json --ect 3G
node scripts/perf/sse.mjs --seconds 180 --out ../../perf/results/slow-network/matched.json
node scripts/perf/network.mjs --seconds 60 --ect 3G --out ../../perf/results/slow-network/browser.json
```

agy-mcpの別々の会話にWeb調査・共有SSEバックエンド・災害の符号化・フロントエンド実装を分担した。agy側で拒否されたURL閲覧とコマンドは権限を変更せず、親側で一次資料を確認し、型修正・差分レビュー・テストと実測を行った。
