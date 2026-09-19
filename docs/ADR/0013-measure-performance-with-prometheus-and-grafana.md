---
title: 性能を Prometheus と Grafana で常時計測し、鮮度・API/SSE・取り込みと DB の指標と k6 の比較試験を持つ
status: accepted
date: 2026-09-19
depends-on: ["0002", "0006", "0010"]
---

# 0013: 性能を Prometheus と Grafana で常時計測し、鮮度・API/SSE・取り込みと DB の指標と k6 の比較試験を持つ

## コンテキスト

これまで性能を測る仕組みはなかった。あったのは次の3つだけだった。

- compose の health check
- コアの `/api/v1/pipeline/status`（ソース別の受信・書き込み・重複排除の件数）
- Plecto の admin `/metrics`（エッジ全体のリクエスト数と遅延ヒストグラム。route ラベルなし）

所要時間は、コアでも Go アダプタでも一切記録していなかった。

ユーザと決めたこと:

- **測る対象:** データ鮮度、API / SSE の応答性能、取り込み処理と DB。フロント（ブラウザ）の体感は対象外。
- **用途:** 常時の状態確認、変更前後の比較、ボトルネック調査、異常時の表示。
- **環境:** 動かすのはこの開発機だけ。
- **目標値:** まず計測だけ行い、SLO は実測を見てから決める。
- **見せ方:** 閲覧は Grafana。異常は画面上で赤くするだけで、外部には通知しない。計測データは 30 日保持。
- **比較の方法:** 実運用のメトリクスを前後で並べる方法と、API 負荷試験の2つ。

この開発機は別プロジェクトと共有しており、そちらの Prometheus / Grafana がすでに動いている。ホストのメモリには余裕がない。

## 決定

### 基盤

compose に次の3つを追加する。

- `prometheus`（`prom/prometheus:v3.14.0`、`127.0.0.1:9290`）
- `grafana`（`grafana/grafana:13.2.2`、`127.0.0.1:3300`）
- `postgres_exporter`（`prometheuscommunity/postgres-exporter:v0.20.1`）

Prometheus の設定は次のとおり。

- 収集は 15 秒ごと、保持は `--storage.tsdb.retention.time=30d`。
- 収集対象は、コア `matrix_whale:6000/metrics`、5つのアダプタの `:2112/metrics`、Plecto `proxy:9090`、`postgres_exporter:9187`、自分自身の9つ。
- Alertmanager は置かない。ルールは `monitoring/prometheus/rules.yml` に書き、発火中のものは Grafana で `ALERTS{alertstate="firing"}` の表として見る。

Grafana の設定は次のとおり。

- データソースとダッシュボード（uid `matrixwhale-perf`）を `monitoring/grafana/` からプロビジョニングする。
- 開発機専用なので、匿名 Admin でログイン画面を出さない。ポートは 127.0.0.1 にだけ公開する。

### コアの計測（Gleam）

Erlang の `prometheus`（prometheus.erl 6.1.3）を依存に入れる。Gleam 側は `src/metrics.gleam` の型付き API と、`src/metrics_ffi.erl` の薄い FFI で包む。`/metrics` は受信側リスナー（:6000）に置く。

ヒストグラムの名前は `_seconds` で終わるが、秒で観測するので、宣言時に `{duration_unit, false}` を付ける。付けないと、prometheus.erl は値をネイティブ時間単位とみなして換算してしまう。

| 指標 | 型 | ラベル | 計り方 |
| --- | --- | --- | --- |
| `matrixwhale_http_requests_total` / `_request_duration_seconds` | counter / histogram | `listener`（`ingest`/`api`）、`route`（テンプレート。未知は `unmatched`）、`method`、`code` | 両ルーターの外側で計る。SSE の `/stream` は所要時間を記録しない |
| `matrixwhale_intake_records_total` | counter | `source`、`outcome`（new/updated/unchanged/stale/repeat） | [[0002]] の `pipeline.Outcome` から数える |
| `matrixwhale_ingest_lag_seconds` | histogram | `source`、`basis`（`updated`/`occurred`） | 下の「鮮度」を参照 |
| `matrixwhale_db_duration_seconds` | histogram | `op` | writer の1回（チャンク1トランザクション）ごとと、定期ジョブ（retention / expiry）ごとに計る |
| `matrixwhale_sse_clients` | gauge | `stream` | hub の購読者数 |
| `matrixwhale_sse_publish_delay_seconds` | histogram | `stream` | hub の `publish`（DB commit 直後に呼ばれる）から、全購読プロセスへの配り終わりまで。1件以上イベントを配ったときだけ記録する |
| `erlang_vm_*` | — | — | prometheus.erl の既定コレクタ |

鮮度の測り方は次のとおり。

- 記録するのは、writer が new または updated と判定した記録だけ。取り込んだ時点で `now − 上流の時刻` を観測する（負の値は 0 に丸める）。
- `basis="updated"` は上流の版の時刻を起点にする。地震は `updated_at`、警報は `sent`、GDACS は `modified_at`。自分たちで縮められる遅れはここだけなので、アラートはこちらにだけ掛ける。
- `basis="occurred"` は地震だけで、起点は発生時刻 `occurred_at`。そのソースで new の記録だけを観測する。3 日前の地震の改訂を「3 日遅れ」と数えないためである。

鮮度の終点は SSE の送出（hub の配り終わり）までとする。各接続がソケットに書き込むところと、ブラウザが受け取るところは測らない。

### アダプタの計測（Go）

`adapters/common/metrics` に client_golang v1.24.1 を使った小さなパッケージを置く（[[0006]]）。

- `Transport(peer, next)` は、上流向けとコア向けの `http.Client` に挟む。
  - `matrixwhale_adapter_http_requests_total{peer, code}` を数える。応答がなければ `code="error"`。
  - `matrixwhale_adapter_http_request_duration_seconds{peer}` を観測する。
  - 2xx か 304 なら `matrixwhale_adapter_last_success_timestamp_seconds{peer}` を更新する。
- EMSC の WebSocket は `websocket_connected` と `websocket_messages_total` で見る。
- 各アダプタの `main` が `metrics.Serve()` を呼び、`METRICS_ADDR`（既定 `:2112`）で公開する。
- ホスト別・フィード別のラベルは付けない。CAP の約 200 フィードの健全性は、すでに `sea.cap_feed` と `/feeds` で見えている。

### 異常の表示（仮の閾値）

| ルール | 条件 |
| --- | --- |
| `TargetDown` | `up == 0` が 2 分続く |
| エラー率 | 直近 10 分で 5% 超が 5 分続く。コアは 5xx、Plecto は 5xx、アダプタ→コアとアダプタ→上流は `code=~"4..|5..|error"` |
| `IngestLagHigh` | `basis="updated"` の p95（15 分窓）が 15 分続けて閾値を超える。閾値は poll 間隔のおよそ2倍 |

補足:

- **エラー率:** Transport はリダイレクトの1ホップごとに記録するため、3xx はエラーに含めない。上流のエラー率は `cap_adapter` を除く。
- **`IngestLagHigh` の閾値:** EMSC 60 s、USGS / NOAA 180 s、GDACS / CAP 600 s。数日分の実測を見て調整する。

### 負荷試験（k6）

`perf/k6/api.js` を `grafana/k6:2.2.0` で動かす。Plecto の 5 rps のレート制限を避けるため、compose ネットワークからコア（`matrix_whale:8080`）を直接叩く。

- **対象:** `alerts/active`、`earthquakes/recent`、`hazards/recent`、`timeline` の1ページ目、カーソルで進んだ2ページ目。
- **シナリオ:** エンドポイントごとに独立した `constant-arrival-rate` で `RATE`（既定 1 req/s）。10 秒の warm-up の後に 60 秒計る。
- **結果:** endpoint 別の count / p50 / p95 / p99 / エラー率と、取りこぼした実行数（dropped iterations）を `perf/results/<UTC>-<sha>.json` に書く（gitignore）。メタデータとして git sha、dirty、loadavg も残す。
- **実行と比較:** 実行は `make perf-api`、比較は `make perf-compare A=… B=…`（`perf/compare.jq`）。

## 根拠（調査結果・出典）

- **考え方の型:** 利用者向けの経路は Golden Signals / RED で見る。値は平均ではなくバケツ付きヒストグラムで持ち、パーセンタイルで見る。データパイプラインは鮮度（freshness）を SLI にする。三つの時刻（event time / ingestion time / delivery time）を区別する。
  - https://sre.google/sre-book/monitoring-distributed-systems/
  - https://sre.google/workbook/data-processing/
  - https://prometheus.io/docs/practices/histograms/
  - https://nightlies.apache.org/flink/flink-docs-release-1.10/dev/event_time.html
- **バッチ処理の要:** 「最後に成功した時刻」を見るのがバッチ系の定石である。https://prometheus.io/docs/practices/instrumentation/
- **Erlang のクライアント:** prometheus.erl は 6.1.3（2026-06）まで保守されており、BEAM の VM コレクタを持つ。https://hex.pm/packages/prometheus 。`_seconds` で終わるヒストグラムは、`duration_unit` を false にしないと値をネイティブ単位として換算する（`prometheus_histogram.erl` 内の注記）。
- **pgo のイベント:** pgo 0.20.0 は `telemetry` イベントを出さない。そのため DB 時間は writer の呼び出しの外側で計る。https://hex.pm/packages/pgo
- **Go のクライアント:** https://pkg.go.dev/github.com/prometheus/client_golang/prometheus 。promhttp の RoundTripper 計測は、transport エラーを数えない。だから自前の Transport を使う。
- **k6:** https://grafana.com/docs/k6/latest/using-k6/thresholds/ 。k6 には SSE が組み込まれていない。使うにはコミュニティ拡張の xk6-sse が要る。https://github.com/phymbert/xk6-sse
- **負荷試験の設計:** 当初は 10 iter/s で、1 回の反復が5つのエンドポイントを順番に叩く設計にした。この設計ではコアが飽和し、応答の大きいエンドポイントに引きずられて、待ち行列の長さしか測れなかった。そのため、エンドポイントごとに独立した低い固定レートに改めた。

## 検討した代替案

- **同じホストの別プロジェクトの Prometheus / Grafana に相乗りする:** 増えるコンテナはゼロになる。しかし設定が別リポジトリに散り、Docker ネットワークをまたぐ配線が要る。MatrixWhale 単体で完結しないので採らない。
- **VictoriaMetrics single を使う:** 省メモリをうたう。しかしこの規模では差が小さい。資料と Grafana の既定の対応でも Prometheus が勝る。
- **TSDB を置かない（`/metrics` を curl し、SQL で都度確認する）:** 最小構成になる。しかし、常時の状態確認と変更前後の比較という用途を満たせない。
- **themis（純 Gleam）や自前実装:** FFI が要らない。しかし VM メトリクスを自分で足す必要があり、保守するコードも増える。
- **pg_stat_statements:** SQL 単位で原因を追える。しかし `shared_preload_libraries` の設定と DB の再起動が要る。writer 単位の時間と postgres_exporter で当面は足りるので、見送る。
- **SSE の負荷試験（xk6-sse）とブラウザ受信までの鮮度:** コミュニティ拡張か、フロントの実装が要る。フロントは今回の対象外なので見送る。
- **Alertmanager での通知:** ユーザが画面表示だけを選んだ。
- **高レート（10 req/s）の負荷試験:** 上記のとおり飽和し、変更前後の比較に使えない。

## 影響とトレードオフ

- **メモリ:** 常駐メモリが増える。大半は Grafana である。
- **ingest lag の性質:**
  - 上流の公開の遅れ（CAP の索引の公開待ちなど）を含むので、傾向として読む。
  - p95 はバケツ境界の間を補間した推定値である。
  - DB を空にして起動すると、backfill で new が大量に出て一時的に膨らむ。
- **SSE 送出遅延の範囲:** hub のキューと fan-out までしか含まない。ソケットへの書き込みとネットワークは含まない。
- **件数の重複:** `/api/v1/pipeline/status` と `matrixwhale_intake_records_total` は一部が重なる。pipeline/status は既存の画面と API のために残す。
- **k6 の結果のぶれ:** 共有の開発機で走るので、同じ負荷でもぶれる。loadavg を結果に残し、比較のときの判断材料にする。
- **Grafana の権限:** 匿名 Admin は 127.0.0.1 限定が前提である。公開環境に出すなら認証を入れ直す。
- **今後の課題:**
  - 数日分の実測を見て、`IngestLagHigh` の閾値と SLO を決める。
  - 計測で見えた `hazards/recent` と `alerts/active` の応答サイズと遅さに対処するかを決める。

## 関連ADR

- [[0002]]: new/updated/unchanged/stale/repeat の判定は、Gleam の取り込みパイプラインの Outcome を使う。
- [[0006]]: アダプタの計測は `adapters/common` に置く。
- [[0010]]: k6 は timeline のカーソル（`before` / `next_cursor`）を1回たどる。
