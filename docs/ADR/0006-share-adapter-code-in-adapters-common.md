---
title: Go アダプタの共通処理を adapters/common モジュールと go.work に集約する
status: accepted
date: 2026-09-18
---

# 0006: Go アダプタの共通処理を adapters/common モジュールと go.work に集約する

## コンテキスト

MatrixWhale の取り込み側は、外部ソースごとに独立した Go サービス（アダプタ）が上流をポーリング・購読し、Gleam コアの `POST /api/v1/<source>_data/send` に JSON エンベロープを転送する構成である。EMSC を追加する時点で、既存の `usgs_adapter` と `noaa_adapter` は次の状態だった。

- 4 つの Go サービス（`usgs_adapter`、`noaa_adapter`、`rss_feed_adapter`、`federation_orchestrator`）がそれぞれ独立した `go.mod` を持ち、`go.work` も共有パッケージも存在しない。
- ほぼ同じ処理が各アダプタにコピーされていた。`adapter/poll_interval.go`（`Cache-Control` / `Expires` / `Retry-After` の解釈、指数バックオフ、ジッタ）、`initialize/logger.go`（`slog.Handler` としてログをコアの `/api/v1/logs` に POST する LogSender）、`adapter/matrix_whale.go`（`poll_meta` + `features` のエンベロープ組み立てと ack の検証）、User-Agent の組み立て。
- コピー同士は既にドリフトしていた。USGS 版の `ComputeBackoff` は `Retry-After` より早く再試行しない（サーバ指示を上限クランプしない）が、NOAA 版は単に floor/ceiling でクランプしていた。USGS 版の LogSender は `MATRIX_WHALE_URL` を環境変数から読み共有 `http.Client` を使うが、NOAA 版はコア URL をハードコードし、ログ 1 行ごとに `http.Client` を生成していた。NOAA 版はコアの ack をまったく検証していなかった。
- `docs/internal/usgs_pipeline.md` は USGS アダプタ導入時に「共通化は 3 つ目のアダプタで行う」と決めており、EMSC がその 3 つ目にあたる。

EMSC アダプタは WebSocket の push 型（[[0007]]）で、ポーリング用の関数群をそのまま使うわけではないが、再接続バックオフ、コアへの送信とack検証、ログ転送はそっくり必要になる。3 度目のコピーを作れば、ドリフトの箇所が 3 か所に増える。

## 決定

Go アダプタの共通処理を 1 つのワークスペースモジュールに集約し、3 アダプタすべてがそれを使う。

- 新モジュール `adapters/common`（module path `matrixwhale/adapters/common`）に次のパッケージを置く。
  - `poll`: `ComputeNextPollDelay`、`ParseRetryAfter`、`ComputeBackoff`、`Jitter`。floor / ceiling / 前回値は引数で受け取り、パッケージ変数を持たない。`ComputeBackoff` は USGS 版の「`Retry-After` より早く再試行しない」意味論に統一する。
  - `core`: Gleam コアのクライアント。`NewClientFromEnv()`（`MATRIX_WHALE_URL`、既定は compose 内のコアアドレス）、`PollMeta{FetchedAt, HTTPStatus, FeatureCount, Bytes, FeedURL, Backfill}`、`Ack{Received, Deduped, Written, Dropped, Message}`（欠落を区別するためポインタ）、`Send(ctx, path, meta, features)`、`ValidateAck(ack, sent)`（`received == sent` かつ `deduped + written + dropped == received`）。
  - `logging`: `NewCoreHandler(client, service)`。LogSender の実装は USGS 版を基に 1 つだけ残す。
  - `useragent`: `Build(product, contactEnvVar, fallback, warnOnce)`。各アダプタの従来の挙動（USGS は連絡先未設定なら製品名のみ、NOAA はプレースホルダを入れて一度だけ警告）を引数で表現する。
- リポジトリ直下に `go.work` を置き、`./adapters/common`、`./usgs_adapter/app`、`./noaa_adapter/app`、`./emsc_adapter/app` を `use` する。スタブのままの `rss_feed_adapter` と `federation_orchestrator` は含めない。`go` ディレクティブは `1.26.0` とし、`toolchain` 行は書かない。
- Docker ビルドはリポジトリ直下をコンテキストにし（`context: .`、`dockerfile: <adapter>/Dockerfile`）、イメージ内で `go work init ./adapters/common ./<adapter>/app` を実行して共有モジュールを解決する。ルートの `go.work` はコピーしない（イメージに含まれないディレクトリを `use` しているため）。ルートに `.dockerignore` を置き、`web/`、`node_modules`、`db/data`、`proxy/plecto` などをコンテキストから除外する。
- CI の `go-adapters` マトリクスに `adapters/common` と `emsc_adapter/app` を加える。
- 各アダプタから重複ファイル（`poll_interval.go` とそのテスト、`initialize/logger.go`、エンベロープ / ack のコード）を削除する。互換用の再エクスポートは残さない。

## 根拠（調査結果・出典）

- ドリフトは実在した。`usgs_adapter/app/adapter/poll_interval.go` と `noaa_adapter/app/adapter/poll_interval.go` の `ComputeBackoff` は `Retry-After` の扱いが異なり、NOAA 版の table-driven テストには「ceiling を超える `Retry-After` はクランプされる」というケースがあった。統合後はこのケースの期待値を USGS 版の意味論（サーバの指示を尊重し、ceiling を超えても待つ）に合わせて書き換えた。サーバが `Retry-After` で明示した待機時間より早く叩くのはレート制限の再発を招くため、USGS 版が正しい。
- NOAA 版 LogSender はコア URL をハードコードしており、`MATRIX_WHALE_URL` で向き先を変えられなかった。共通クライアントに寄せたことで、NOAA も環境変数で向き先を切り替えられるようになった。
- Go の workspace モードでは `use` に列挙したモジュールが `require` / `replace` なしで解決される（[Go Modules Reference: Workspaces](https://go.dev/ref/mod#workspaces)）。`go work sync` は変更なしで完了した。
- `go.work` の `go` ディレクティブは、当初アダプタの `toolchain go1.26.8` に合わせて `1.26.8` としたが、開発機の Go は 1.26.4 で、IDE の gopls が `go.work requires go >= 1.26.8 (running go 1.26.4)` でワークスペースを読めなくなった。`go` ディレクティブはワークスペースの最小要件なので `1.26.0` に下げ、4 モジュールとも `GOTOOLCHAIN=local go vet ./...` が 1.26.4 で通ることを確認した。CI（`go-version: "1.26.8"`）と Dockerfile（`golang:1.26.8-alpine3.23`）は明示的に 1.26.8 を使うため影響はない。
- 検証: `adapters/common`、`usgs_adapter/app`、`noaa_adapter/app`、`emsc_adapter/app` それぞれで `go vet ./...` と `go test -race ./...` が通り、`gofmt -l` は空。`docker compose build usgs_adapter noaa_adapter emsc_adapter` が成功し、`.dockerignore` によりビルドコンテキストの転送量はサービスあたり数十 KB に収まった。再構築したスタックで 3 アダプタが実データを配信し、コアの ack 検証（`ValidateAck`）を通過している。

## 検討した代替案

- **3 度目のコピーで独立モジュールを維持する**: これまでの慣例には沿うが、既に 2 コピーの時点でバックオフ意味論と URL の扱いがずれていた。3 つ目を足せばドリフト箇所が増えるだけで、`usgs_pipeline.md` が「3 つ目で共通化」と決めていた線をここで守った。
- **`go.work` を使わず各 `go.mod` に `replace matrixwhale/adapters/common => ../../adapters/common` を書く**: Docker ビルドでは動くが、ローカル開発でも `replace` 経由になり、モジュールを 1 つ足すたびに全 `go.mod` を編集する必要がある。`go.work` なら `use` を 1 行足すだけで済み、Docker 側は `go work init` で必要な 2 モジュールだけの一時ワークスペースを作れる。
- **ルートの `go.work` をイメージにコピーする**: `use` に列挙した全ディレクトリがコンテキストに必要になり、EMSC のイメージに USGS / NOAA のソースを含めることになる。イメージ内で `go work init` する方式なら、そのアダプタと `adapters/common` だけで閉じる。
- **vendoring**: 共通コードを各アダプタにベンダするのはコピーと同じ問題を別の形で持ち込む。
- **1 バイナリのマルチコマンド化（全ソースを 1 つの Go プログラムに統合）**: 共通化は最大になるが、compose のサービス分割（ソースごとの再起動・ログ・環境変数）と `depends_on` の構造を壊す。ソースを足すたびにアダプタを 1 サービスとして足す現在の運用を維持した。
- **`federation_orchestrator` と `rss_feed_adapter` も `go.work` に含める**: どちらも health エンドポイントだけのスタブでデータ経路の外にある。ワークスペースに入れると CI マトリクスとビルド対象が増えるだけなので、実装が始まるまで除外した。

## 影響とトレードオフ

- **得るもの**: バックオフ、エンベロープ、ack 検証、ログ転送、User-Agent の実装が 1 か所になり、NOAA も `MATRIX_WHALE_URL` と ack 検証（`deduped + written + dropped == received`）を得た。EMSC アダプタは再接続バックオフとコア送信を新規に書かずに済んだ。
- **Docker コンテキストの拡大**: アダプタのイメージはリポジトリ直下をコンテキストにするため、`.dockerignore` の維持が必須になった。除外漏れがあるとビルドが遅くなる。
- **`go.work` の保守**: モジュールを追加するたびに `use` を足し、CI マトリクスも更新する必要がある。忘れるとローカルでは動くが CI で落ちる。
- **NOAA の挙動変更**: NOAA アダプタのバックオフは USGS 版の意味論に変わった（ceiling を超える `Retry-After` を尊重する）。NWS が長い `Retry-After` を返した場合、従来より長く待つ。
- **compose の volume マウント**: 各アダプタの `./<adapter>/app:/app` マウントは残しているが、イメージには compile 済みバイナリが入るためホットリロードにはならない。以前からの状態で、今回は触っていない。
- **今後の課題**: WIS2（MQTT）や MSC（AMQPS）の push 型アダプタを足すときは、`emsc_adapter` の購読ループとバッチャ（[[0007]]）を `adapters/common` に上げるかを判断する。2 つ目の push 型が出るまでは EMSC 固有のままにする。

## 関連ADR

- [[0002]] Gleam intake パイプライン。`core.ValidateAck` が前提にする ack の不変条件はコア側の計数契約と対になる。
- [[0007]] EMSC アダプタ。このモジュールの最初の新規利用者で、`poll.ComputeBackoff` を再接続と FDSN 再試行に、`core.Send` / `ValidateAck` を配信に使う。
