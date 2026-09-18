---
title: スキーマ管理を Atlas の versioned migrations に一本化する
status: accepted
date: 2026-09-18
---

# 0001: スキーマ管理を Atlas の versioned migrations に一本化する

## コンテキスト

これまで `sea` スキーマの DDL は二か所に分かれて存在していた。

- `db/init/init.sql`: Postgres イメージの entrypoint が **volume 初期化時に一度だけ** 実行する。`CREATE DATABASE sea`、`CREATE SCHEMA sea`、テーブルとインデックスの作成をまとめて担っていた。
- `matrix_whale/matrix_whale/src/repository/initialize_db.gleam`: Gleam コアの起動時に `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` / `DO $$ ... EXCEPTION WHEN duplicate_object` を再実行する。開発用の volume が永続化されるため `init.sql` が二度と走らず、スキーマ追加のたびに volume を消せない、という事情への対処だった。

この構成には次の問題があった。

- 同じ DDL が二か所にあり、どちらが正か分からない。実際 `init.sql` にだけ存在する `sea.severity` テーブルはアプリのどこからも参照されていない dead schema だった。
- 「あるべき姿」と「差分」の区別がなく、レビュー可能なマイグレーション履歴が存在しない。
- 起動時に DDL を流す設計は、アプリケーションが DDL 権限を持ち続けることを前提にし、起動失敗の原因にもなる。
- 前処理・重複排除基盤 (idea2 §6) では `sea.source`、`sea.event`、`sea.event_member` など複数のテーブル追加と既存テーブルへの FK 追加が続くことが分かっていた。

ユーザからの制約は二つ。「SQL にロジックを持たない (なるべく)」、そして「マイグレーションには Go 製の Atlas を導入する」。

## 決定

スキーマの正本を `db/schema.sql` (desired state) に置き、Atlas の **versioned migrations** ワークフローでマイグレーションを生成・適用する。

- `db/atlas.hcl` に env `local` を定義する。`src = "file://schema.sql"`、`migration.dir = "file://migrations"`、`dev = "docker://postgres/16/dev"`、`url = getenv("MATRIX_WHALE_DATABASE_URL")`、`schemas = ["public", "sea"]`。
- スキーマ変更の手順は「`db/schema.sql` を編集 → `make db-diff name=<change>` で `db/migrations/<timestamp>_<change>.sql` を生成 → 生成物をレビュー → `docker compose up` で適用」。`make db-apply` / `make db-status` も用意する。
- `compose.yaml` に one-shot サービス `migrate` (`arigaio/atlas:1.3.3-alpine`、`restart: "no"`) を追加し、`db` が healthy になってから `migrate apply` を実行する。`matrix_whale` は `depends_on: migrate: condition: service_completed_successfully` で、マイグレーション完了後にしか起動しない。
- `db/init/` と `db/Dockerfile` の `COPY init.sql` を削除し、`initialize_db.gleam` からは `ensure_alert_schema` / `ensure_earthquake_schema` を削除する。データベース `sea` 自体は compose の `POSTGRES_DB` で Postgres イメージに作らせる。
- dead な `sea.severity` は持ち込まない。前処理基盤で必要になる `sea.source` を最初のマイグレーションに含める。
- `pg_trgm` 拡張は最初のマイグレーションファイル `db/migrations/20260917165144_init.sql` の先頭に `CREATE EXTENSION IF NOT EXISTS pg_trgm;` として置く。同じ文を `db/schema.sql` にも残す (理由は根拠を参照)。
- DB 統合テストは `make test-core` に一本化する。`db/scripts/test_core.sh` が使い捨ての `postgres:16` コンテナを起動し、Atlas でマイグレーションを適用してから `gleam test` を走らせ、`trap` で必ずコンテナを消す。テスト用の環境変数は `MATRIX_WHALE_TEST_DATABASE_URL`、DB 名の安全ガードは接頭辞 `matrixwhale_test` に改める。
- 開発用の Postgres volume (`db/data`) は作り直す。保持していたデータは 7 日分の地震と active なアラートだけで、再ポーリングで復元できる。

## 根拠（調査結果・出典）

- Atlas は versioned と declarative の二つのワークフローを持ち、レビュー可能な履歴と本番への適用を重視するなら versioned を勧めている。https://atlasgo.io/concepts/declarative-vs-versioned
- `migrate diff` は使い捨ての dev database 上で既存マイグレーションを replay し、desired state との差分を計算する。SQL を構文解析するだけでは制約やデフォルトの妥当性を検証できないため dev database が必須になる。https://atlasgo.io/concepts/dev-database
- `atlas migrate lint` は v0.38 (2025-10-30) 以降 Atlas Pro 限定 (`atlas login` が必要) になった。Community edition のビルドには `migrate lint` コマンド自体が存在しない。`migrate diff` / `migrate apply` / `migrate hash` / `--baseline` はログインなしで動く。https://atlasgo.io/versioned/lint 、https://atlasgo.io/community-edition
- Postgres の拡張 (extension) の管理も Pro 限定で、ログインなしの binary では `CREATE EXTENSION` が inspect / diff の出力に一切現れない。実機で確認済み (v0.36.2 で `docker { baseline }` ブロックは `requires 'atlas login'` で失敗)。そのため拡張はマイグレーションファイルに素の SQL として置くしかない。一方 `migrate diff` は `schema.sql` を**別の**素の dev database に流して desired state を実体化するため、`schema.sql` 側に `CREATE EXTENSION` が無いと `operator class "gin_trgm_ops" does not exist` で失敗する。両方に置くのは Atlas がこの制約を持つ限り必要な重複であり、`schema.sql` 側のコメントに明記した。
- schema-scoped URL (`?search_path=sea`) は対象スキーマが `url` と `dev` の両方に**既に存在する**ことを要求し、Atlas 自身は作れない。database-scoped URL に切り替えると今度は `schemas` を絞らない限り `public` しか見ず「差分なし」と誤報し、`schemas = ["sea"]` だけにすると live DB の `public` を DROP しようとする。`schemas = ["public", "sea"]` で両方解決することを実機で確認した。
- Postgres 公式イメージの entrypoint は初期化中に **Unix socket のみで listen する一時サーバー** を起動してから本サーバーに切り替える。コンテナ内の `pg_isready` (socket 経由) は一時サーバー段階でも成功するため、直後の `migrate apply` が `connection reset by peer` になる競合が実際に起きた。`test_core.sh` の readiness は `pg_isready -h 127.0.0.1` (TCP) で本サーバーだけを検知する。
- 検証結果: 素の `docker run postgres:16` に `migrate apply` を流して拡張・4 テーブル・10 インデックスが作成されること、`make db-diff name=noop_check` が `no changes to be made` を返すこと、`make test-core` が 32 件 (導入時点) → 79 件 (基盤完成時点) pass することを確認した。実スタックでも `migrate` サービスが 4 本のマイグレーションを適用してからコアが起動した。
- ローカルの `atlas` CLI は v0.36.2 (canary)、compose のイメージは 1.3.3。生成物は素の SQL と `atlas.sum` なので版差による問題は出ていない。

## 検討した代替案

- **declarative (`atlas schema apply`) のみ**: `schema.sql` を直接 live DB に適用する。手順は最も単純だが、本番相当の DB に対する変更内容が実行時にしか分からず、レビュー可能な履歴が残らない。不採用。
- **Atlas HCL で desired state を書く**: SQL より構造化されるが、チームは SQL DDL を読む方が速く、`schema.sql` はそのまま `psql` でも検証できる。学習コストに見合わない。不採用。
- **Gleam 起動時の DDL をセーフティネットとして残す**: 二重管理を温存することになり、Atlas 側の履歴と実態が乖離する元になる。ユーザの「一本化」の指示とも合わない。不採用。
- **Community edition イメージ (`-community`)**: ライセンスが Apache-2.0 で明確だが、`migrate lint` / `checkpoint` / `down` が永続的に使えない。標準イメージなら将来 `atlas login` するだけで lint を足せる。標準イメージを採用し、lint は当面見送る。
- **既存 volume を `--baseline` で引き継ぐ**: 手順は一つ増えるだけだが、既存 volume には collation 不整合や dead テーブルが残っており、データも再ポーリングで戻る。作り直しを選んだ。
- **拡張を `db/init/init.sql` に残す**: 当初はこうしたが、`make db-diff` が素の dev database で replay できず、稼働中の DB を `--dev-url` に指すという危険な回避策が必要になった (Atlas は dev database を作業台として書き換える)。マイグレーション #1 に移して解決した。

## 影響とトレードオフ

- 得るもの: スキーマの正本が一つになり、変更は生成された SQL としてレビューできる。アプリから DDL が消え、起動順序 (`db` → `migrate` → `matrix_whale`) が compose に明示される。DB 統合テストが `make test-core` 一発で再現可能になった。
- 失うもの: `migrate lint` による破壊的変更の自動検出はログインするまで使えない。CI では Postgres を立てず、DB 統合テストはローカルの `make test-core` に限る (ユーザ判断)。
- 引き受けるリスク: `pg_trgm` の宣言が `schema.sql` とマイグレーション #1 の二か所にある。Atlas が拡張を管理できるようになったら `schema.sql` 側へ寄せる。`make db-diff` には Docker が必要。ローカル CLI とイメージの版差はいずれ揃える。
- 運用: 既存の開発環境は volume を作り直す必要がある (`docker compose down` → `db/data` を空にする → `docker compose up --build`)。テストの環境変数名が `USGS_TEST_DATABASE_URL` から `MATRIX_WHALE_TEST_DATABASE_URL` に変わった。
- 今後の課題: マイグレーションの後方互換チェック (lint 相当) を CI で担保する方法。Atlas Pro を使うか、`make db-diff` の結果が空であることだけを CI で確認するか。

## 関連ADR

- [[0002]] intake パイプラインは本 ADR の `sea.source` と FK 追加のマイグレーションを前提にする。
- [[0003]] `sea.event` / `sea.event_member` とインデックス修正は本 ADR の手順で追加した。
- [[0004]] `sea.source` マスタは本 ADR の最初のマイグレーションで作成した。
