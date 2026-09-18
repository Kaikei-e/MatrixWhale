---
title: 取り込みの重複判定を SQL から Gleam の intake パイプラインへ移す
status: accepted
date: 2026-09-18
depends-on: ["0001"]
---

# 0002: 取り込みの重複判定を SQL から Gleam の intake パイプラインへ移す

## コンテキスト

MatrixWhale の取り込みは、Go アダプタ (NOAA / USGS) が上流の JSON をそのまま `matrix_whale` (Gleam) に POST し、コアが Postgres に書き込む構造になっている。重複排除はコアの SQL に埋め込まれていた。

- USGS: `INSERT ... ON CONFLICT (source, source_id) DO UPDATE SET ... WHERE excluded.updated_at_ms > sea.earthquake.updated_at_ms RETURNING ..., (xmax = 0)`。「どの revision が勝つか」と「new か update か」の両方を SQL が判定する。
- NOAA: `ON CONFLICT (id) DO UPDATE ... WHERE sea.alert.sent IS DISTINCT FROM EXCLUDED.sent OR message_type IS DISTINCT FROM ... OR ended_at IS NOT NULL` と `(xmax = 0) AS is_new`。判定条件がソースごとに異なる独自の SQL になっていた。
- アプリ層には seen-set もハッシュも無く、同じレコードが毎ポーリング (USGS は 60 秒ごとに約 200 件、NOAA は 30 秒ごとに約 170 件) DB まで届いていた。
- `docs/internal/usgs_pipeline.md` §5.3 は Bloom / TTL seen-set と cross-source 照合を「WIS2 / MSC の多重購読段階まで先送り」と記録していた。idea2 §1 は WIS2 の Global Broker が複数購読で同じ通知を重複配信すること、受信側にも同じ仕組みが要ることを指摘している。

ユーザの方針は「SQL にロジックを持たない (なるべく)」。制約 (PK / UNIQUE / FK) と単純な CRUD は SQL でよいが、勝ち負けの判定や分類はアプリ側で読める・テストできる形にする。

## 決定

ソースに依存しない intake パイプラインを Gleam コアに置き、判定をすべて Gleam の関数で行う。

- `src/intake/record.gleam`: `Key(source, source_id)`、`Incoming(key, revision, payload)`、`Verdict = New | Updated(previous) | Unchanged | Stale(current)`、純粋関数 `classify(incoming, current: Dict(Key, Int))`。`revision` はソースごとの単調増加整数 (USGS: `updated` ms、NOAA: `sent` の unix ms、EMSC: `lastupdate` ms)。同一バッチ内の重複キーも最大 revision だけを残す。
- `src/intake/seen_set.gleam` + `src/intake_seen_set_ffi.erl`: 公開の named ETS テーブルによる TTL 付き seen-set。キーは `source|source_id|revision`、TTL は既定 1 時間 (`INTAKE_SEEN_TTL_MS` で変更可)。`unseen` は読み取りのみ、`mark` は **トランザクション commit 後にのみ** 呼ぶ。60 秒ごとに `purge`。
- `src/intake/pipeline.gleam`: `run(records, seen, now_ms, write)` が seen-set で既知の revision を `repeats` として落とし、生き残りを 250 件のチャンクに分けて `write` (1 チャンク = 1 トランザクション) に渡し、各チャンクの成功直後にその分だけ `mark` する。チャンク N が失敗したら `Error` を返し、それ以前のチャンクは commit 済み・mark 済みのまま残す。
- 書込側 (`earthquake_writer.write_batch` / `alert_writer.write_batch`) は 1 トランザクション内で `SELECT ... FOR UPDATE` により現在の revision を読み、`classify` の結果に従って `INSERT ... ON CONFLICT DO NOTHING RETURNING` (制約のみのセーフティネット) と `UPDATE ... RETURNING` を実行し、revision ログを追記する。`WHERE excluded.... >` や `xmax` は使わない。
- アラートの生存管理 (`revive` / `touch` / `sweep_missing` / `sweep_expired`) は集合更新の `UPDATE ... WHERE id = ANY($1)` として残し、`now` は SQL の `now()` ではなく Gleam から引数で渡す。復活したアラートは `updated` として SSE に流す。
- 数え方の契約を固定する: `received == deduped + written + dropped`、`deduped = repeats + unchanged + stale`、`written = new + updated`、`dropped = デコード失敗 + 保持期間外 + Test`。NOAA のレスポンスも USGS と同じ `{received, deduped, written, dropped, message}` に統一し、Go アダプタは共通の `core.ValidateAck` で検証する。`GET /api/v1/pipeline/status` は `deduped` を保ったまま内訳 `dedup: {intake, unchanged, stale}` と `matched` を追加する。

## 根拠（調査結果・出典）

- WIS2 Guide は Global Broker がメッセージ `id` で、Global Cache が `data_id` + `pubtime` で重複を捨てること、利用者側でも約 1 時間分の `id` / `data_id` を保持して多重経路の重複を落とすことを勧めている。seen-set の TTL 既定値 1 時間はこれに合わせた。https://wmo-im.github.io/wis2-guide/guide/wis2-guide-APPROVED.html
- 既存の冪等キー `(source, source_id, revision)` は `docs/internal/usgs_pipeline.md` §5.1 で決まっていた。本 ADR はその判定の置き場所を SQL から Gleam に移すもので、キー自体は変えていない。
- 実スタックでの計測: 2 回目以降のポーリングは seen-set で全件 intake 段階で落ち、DB に届かない (USGS 195/195、NOAA 170/171)。1 回目の書込は従来どおり全件 `new` になる。
- チャンク分割の根拠: EMSC の 7 日分 backfill (2,413 件) を 1 トランザクションで書くと、`pog` の既定クエリタイムアウト (5,000 ms) により約 5.3 秒で `QueryTimeout` になった。Postgres の slow log では 300 ms を超える文は 1 件 (456 ms の INSERT) だけで、1 行あたり 8〜10 クエリ × 2,413 行の往復とイベント候補検索の seq scan (インデックスが `occurred_at`、クエリは `occurred_at_ms`) の合計が閾値を越えていた。250 件チャンク化とインデックス修正の後、同じバッチが 4.9〜7.1 秒で HTTP 200 (`written 2384, dropped 29`、29 件は保持期間外) になった (commit fdd2723)。
- seen-set の mark を commit 後に限定する理由: 先に mark すると、DB 障害で 503 を返した後のアダプタ再送が seen-set で捨てられ、TTL が切れるまでデータが失われる。統合テスト「failed write does not mark the seen-set」で担保する。
- 検証: `make test-core` 79 件 pass (純粋関数の `record` / `seen_set` / `pipeline` テスト、地震・アラートの DB 統合テスト、HTTP 往復と 503 経路を含む)。`gleam format --check` clean。NOAA アダプタに追加した `matrix_whale_test.go` で ack 検証の失敗がエラーとして伝わることを確認。

## 検討した代替案

- **SQL の述語をそのまま使い続ける**: 往復回数は最少だが、判定がソースごとに別々の SQL に散り、ユニットテストできず、xmax のような Postgres 固有のトリックに依存する。ユーザ方針に反する。不採用。
- **Go アダプタ側で重複排除する**: アダプタの状態はプロセスメモリだけで再起動で消え、複数アダプタ (WIS2 の多重購読、MSC の 2 系統) にまたがる重複はアダプタからは見えない。判定はコア一か所に集約した。不採用。
- **Bloom filter**: メモリ効率は良いが偽陽性があり、revision 単位の厳密な判定 (Stale の検出) ができない。ETS の set で十分な規模 (数万キー) なので不採用。
- **seen-set を置かず DB の制約だけに頼る**: 判定は Gleam に移せるが、毎ポーリングの全件が `SELECT FOR UPDATE` を通り、ポーリング間隔が短いソースほど無駄が増える。不採用。
- **バッチ全体を 1 トランザクションで書く**: 原子性は最も単純だが、大きな backfill でタイムアウトすることが実測で分かった。チャンク単位の原子性 + seen-set による再送の冪等性で代替した。
- **`ON CONFLICT DO NOTHING` も使わない (SELECT → 判定 → INSERT)**: 同時実行時の重複 INSERT が unique violation でトランザクション全体を失敗させる。制約のみの `DO NOTHING` は「SQL に判定を持たない」方針の範囲内と判断し、負けた INSERT は `unchanged` に数える。

## 影響とトレードオフ

- 得るもの: 判定ロジックが `intake/record.gleam` の純粋関数に集まり、ソースが増えても `Incoming` に正規化するだけで同じ経路を通る。DB は制約と CRUD だけになった。ポーリング型ソースの繰り返し配信は DB に届く前に消える。
- 失うもの: 1 行あたりの往復が増えた (SELECT + INSERT/UPDATE + revision ログ、以前は 1 upsert)。seen-set はプロセス再起動で消える (DB の制約が backstop になるので正しさは保たれ、コストだけ戻る)。
- 引き受けるリスク: チャンク境界での部分成功 (前半 commit、後半 503)。アダプタは同じバッチを再送し、前半は `repeats` として落ちるので二重書込にはならないが、アダプタ側の ack 検証は「1 回の POST 全体」に対して行われる点を README に記した。`stale` な revision も seen-set に記録するため、逆順に届いた古い revision は TTL 内で再判定されない (意図どおり)。
- 運用: `deduped` の意味が「upsert の no-op 数」から「seen-set + unchanged + stale」に広がったが合計の不変条件は変えていないため、Go アダプタと README の契約はそのまま成立する。
- 今後の課題: seen-set の永続化 (再起動直後の無駄なフル書込を避ける)、WIS2 のように `id` と `data_id` の二種類のキーを持つソースへの拡張、チャンクサイズ (250) の実測に基づく見直し。

## 関連ADR

- [[0001]] 本 ADR の `sea.earthquake.source` FK と `sea.source` は Atlas のマイグレーションで追加した。
- [[0003]] cross-source 照合は本 ADR の書込トランザクション内で、New / Updated 行に対してのみ走る。
- [[0004]] `Key.source` の値はソースレジストリの id と一致させ、FK で担保する。
- [[0006]] Go アダプタ側の ack 検証 (`core.ValidateAck`) は本 ADR の数え方の契約を前提にする。
- [[0007]] EMSC は本 ADR の経路をそのまま通る 3 つ目のソースであり、チャンク化の契機になった。
