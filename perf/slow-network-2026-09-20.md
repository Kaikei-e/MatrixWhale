# 低帯域環境の実測と改善（2026-09-20）

## ユーザー環境の Lighthouse

入力は 01:55:30 の初回計測と、実装反映後にユーザーが取得した 02:24:10 の再計測。両方とも Lighthouse 13.4.1、desktop、simulate、RTT 40 ms / 10,240 Kbps / CPU slowdown 1 の設定。実際の接続環境はユーザー環境に依存する。

| 指標 | 01:55:30 | 02:24:10 |
| --- | ---: | ---: |
| Performance | 43 | 67 |
| FCP | 1.803 s | 1.154 s |
| LCP | 5.242 s | 2.295 s |
| TBT | 395.5 ms | 329.0 ms |
| Speed Index | 5.378 s | 2.306 s |
| total-byte-weight | 20,132,067 B | 4,816,707 B |

総転送量はレポート上で 76.1% 減少。主なリクエストの変化は次のとおり（ヘッダーを含む Lighthouse の transferSize）。

| 対象 | 改善前 | 改善後 |
| --- | ---: | ---: |
| 災害一覧 | 8,719,268 B | 2,104,818 B |
| 有効な警報一覧 | 3,996,502 B | 574,669 B |
| NWS 地理データ 4 ファイル | 各 3 回取得 | 各 1 回取得 |
| 陸地データ | 2 回取得 | 1 回取得 |
| 配信元一覧 | 2 回取得 | 1 回取得、9,819 B |

この比較にはライブデータの差も含まれる。特に hazards SSE は前回 1,870,498 B、今回は 294 B で、配信中のイベント数が異なる。SSE の減少分を圧縮の効果として扱わない。両レポートにはブラウザー拡張のリクエストもある。後述の制御測定は拡張のない新しい Chromium コンテキストを使用した。

02:24:10 のレポートは、最後に追加した地理データの同時取得制限を含まない版の測定である。

## 実装

- Gleam/Mist の JSON レスポンスを、クライアントの `Accept-Encoding` に応じて gzip 圧縮する。元のデータ、座標、件数を維持する。SSE は圧縮対象から除外する。
- 圧縮版と非圧縮版の ETag を分離し、`Vary: Accept-Encoding` と正しい Content-Length を返す。`gzip;q=0`、identity 優先、弱い ETag、条件付き GET を検証した。
- 災害一覧では、毎回変わる `generated_at` だけでキャッシュが無効化されていた。災害データと件数から弱い ETag を生成し、内容が同じなら 304 を返す。
- バージョン付き地理データを URL ごとの共有 Promise で一度取得し、GeoJSON オブジェクトとして MapLibre に渡す。テーマや警報状態の変更で再ダウンロードしない。失敗した取得はキャッシュから除去し、再試行できるようにする。
- 地理データのダウンロードを最大 2 本・低優先度にし、初期一覧と SSE 接続用の通信枠を確保する。
- 地震と災害のストアで配信元一覧の同時リクエストを共有する。完了後は固定キャッシュにせず、再接続時には新しい一覧を取得する。
- 警報一覧の固定 10 秒タイムアウトを、データ受信で更新する 10 秒の無通信タイムアウトに変更する。全体の上限は 120 秒。切断・再接続によるキャンセルと SSE の差分反映を維持する。

agy-mcp の別々の会話に Web 調査、API 圧縮、地理データ、配信元・警報処理を分担した。サブエージェントで拒否されたコマンドや URL アクセスは権限を変更せず、親エージェントの利用可能な Web ツールで一次資料を確認し、差分レビュー・修正・実測を行った。

## API 単体の帯域制限測定

実際の `http://localhost:8180` を経由し、curl の `--limit-rate 200000`（1.6 Mbps）でレスポンスボディを保存した。改善後は `Accept-Encoding: gzip` を指定し、自動展開せずに転送量を計測した後、gzip 展開と JSON パースを検証した。

| 対象 | 改善前ボディ | 改善後ボディ | 改善前の完了時間 | 改善後の完了時間 |
| --- | ---: | ---: | ---: | ---: |
| 災害一覧 | 8,719,056 B | 2,104,552 B | 43.162 s | 10.495 s |
| 有効な警報一覧 | 4,157,044 B | 574,406 B | 20.581 s | 2.394 s |

改善後の展開サイズは災害 8,719,024 B / 1,008 件、警報 4,352,392 B / 1,963 件、配信元 121,154 B / 307 件。配信元の転送量は 9,662 B。改善前後でライブデータが更新されているため、同一スナップショットではない。curl の速度制限は特に小さいレスポンスでは短時間のバーストを含む。

再検証では、空の災害一覧でも時刻だけで ETag が変わる旧動作を確認し、修正後は 23 秒を挟んでも同じ ETag で **304 / ボディ 0 B** となった。異なる Content-Encoding の ETag では 200 を返す。SSE は `text/event-stream`・Content-Encoding なしで即時に heartbeat を受信した。

## ブラウザーの帯域制限測定

Chromium 153.0.8010.12、1280 × 900、新しいコンテキスト、キャッシュ初期化、CDP で下り 1,600 Kbps・上り 750 Kbps・遅延 150 ms、CPU 制限なし。`/globe` を開き 90 秒観測する。最初に各タブの件数が 0 より大きくなった時刻を記録する。Lighthouse のシミュレーション値とは直接比較しない。

改善前は 2 回とも警報の取得が約 10 秒で中断し、90 秒後も Alerts は 0 件。災害リクエスト自体は 58.192 / 58.319 秒かかった。件数検出を修正した 2 回目の測定を UI 表示時間の基準とする。

最初の実装では災害の初期表示は約 63 秒から約 29 秒になったが、地理データを一斉に取得することで地震の初期表示が 9.389 秒から 14.768 秒に遅れた。この実測を受け、地理データの同時取得制限を追加した。

最終測定結果は `results/slow-network/browser-after-2.json` に保存した。

| 件数が初めて表示されるまで | 改善前（2 回目） | 最終版 |
| --- | ---: | ---: |
| Timeline | 7.067 s | 3.267 s |
| Earthquakes | 9.389 s | 5.093 s |
| Hazards | 62.952 s | 26.167 s |
| Alerts | 取得中断、90 秒後も 0 件 | 11.150 s |

最終版のブラウザー実測 LCP は 5.080 秒（改善前 9.384 秒）、警報リクエストの所要時間は 8.434 秒。ページエラーと失敗リクエストは 0。地理データ 5 ファイルと配信元一覧は各 1 回取得した。ライブデータは測定間で更新されており、Timeline の転送量も異なるため、各時刻は測定したランの比較として扱う。

## 再現と検証

稼働中のサービスに対して、以下を `web/app` で実行する。

```sh
node scripts/perf/api.mjs --out ../../perf/results/slow-network/api-new.json
node scripts/perf/network.mjs --out ../../perf/results/slow-network/browser-new.json --seconds 90
```

対象 URL、帯域、遅延はスクリプトの引数で変更できる。再現スクリプトはリポジトリに含め、取得結果は既存の gitignore 対象 `perf/results/slow-network/` に置く。ここには元レポートの解析用コピー、API 前後、ブラウザー前後、HTTP 検証を保存した。最初の入力は JSON の前に `codex` があったため、解析用コピーでは最初の `{` 以降を読む。元ファイルは変更していない。

実施した検証:

- `pnpm check`: エラー・警告 0。
- `pnpm exec vitest run`: 24 ファイル、256 テスト通過。
- `gleam test`（`matrix_whale/matrix_whale`）: 275 テスト通過。DB 接続を要する統合テストはこの検証に含めない。
- `pnpm exec playwright test tests/network.spec.ts tests/globe.spec.ts tests/alerts.spec.ts --workers=2`: 15 テスト通過。同時取得制限追加後に network テストを再実行し通過。
- `docker compose build web matrix_whale`: 成功。`docker compose up -d --no-deps web matrix_whale` で localhost:8180 の配信元に反映。
- 実 HTTP の gzip 展開、identity、q=0、ETag/304、SSE、ブラウザーのリクエスト数とページエラーを確認。

## 一次資料

- [RFC 9110: ETag と Content-Encoding](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.3.3): 圧縮表現を区別する ETag と条件付きリクエストの根拠。
- [MapLibre GeoJSONSource](https://maplibre.org/maplibre-gl-js/docs/API/classes/GeoJSONSource/): URL と GeoJSON オブジェクトの入力、setData の動作。
- [SvelteKit adapter-node](https://svelte.dev/docs/kit/adapter-node): 静的ファイルの事前圧縮と動的応答の圧縮。今回は測定で大きかった Gleam API に実装した。
- [Chrome DevTools Protocol Network](https://chromedevtools.github.io/devtools-protocol/tot/Network/): 帯域制限、転送量、SSE の測定。

## 追加改善：03:13 の再計測を受けて

追加で提供されたレポートの `fetchTime` は 03:13:08 JST。スコア 60、FCP 1.190 秒、LCP 2.421 秒、Speed Index 3.662 秒、TBT 366.5 ms、総転送量 4,731,113 B。重複取得はなく、災害一覧 2,099,295 B、警報一覧 547,167 B、静的な地理データ 5 ファイル 1,621,429 B が残っていた。

ライブの災害一覧を分解すると、JSON 8,693,168 B のうち `primary_geometry` が 7,697,222 B（約 89%）。1,005 件、421,656 座標点を実際に数え、各座標が小数 4 桁以内で完全に表現できることを確認した。また、一覧で返さない `geometries` を DB から 28,794,654 B 読み出していたことを読み取り専用 SQL で確認した。

### 追加実装

- `geometry=polyline` を指定した災害一覧では、隣接座標の差分を文字列で送る。各 geometry に必要な小数桁数を検証し、完全に復元できる場合だけ符号化する。形状の単純化、頂点の削除、座標の丸め落としは行わない。対応しない geometry は通常の GeoJSON で送る。ブラウザーで通常の GeoJSON に復元してからストアに保存する。
- 指定なしの API、詳細 API、SSE は従来の形式を維持する。ETag は選択した表現ごとに検証する。
- 静的な地理データも同じ方式で圧縮し、dev/build 時にローカルの既存データから生成する。座標、穴、フィーチャー ID、属性を保持する。生成物は gitignore 対象とし、元ファイルも引き続き配信する。
- 災害一覧の SQL は、未使用の詳細 geometry 列を NULL に置き換えて読む。詳細画面用の問い合わせは元のデータを取得する。DB 統合テストで、一覧 JSON の一致と詳細の取得を確認した。
- MapLibre を含む地図部分を動的 import に分割し、地図の JavaScript が届く前に各一覧の通信を開始する。地図モジュールを意図的に保留しても 3 種の一覧取得が始まることをブラウザーテストで確認した。

agy-mcp に API、ブラウザーの復元処理、静的データ生成、地図の分割を分担させた。親エージェントで不要な重複実装の整理、型・テストの修正、レビュー、実配信経路での検証を行った。

### 稼働 API の比較

下り 200,000 B/s で、同じ稼働環境の通常形式と `geometry=polyline` を順番に取得した。

| 指標 | 通常形式 | 座標を差分符号化 |
| --- | ---: | ---: |
| gzip 転送量（ボディ） | 2,099,286 B | 972,618 B |
| gzip 展開後の JSON | 8,693,168 B | 2,449,257 B |
| TTFB | 2.608 s | 1.104 s |
| 取得完了まで | 10.166 s | 4.464 s |
| Node 上の JSON パース | 63.539 ms | 5.423 ms |
| Node 上の座標復元 | 不要 | 34.536 ms |

比較中に更新されたレコードは 0 件。1,005 件の全フィールドと 421,656 座標点が、実際の Gleam API → ブラウザーと共通の TypeScript 復元処理を通して完全一致した。転送量はさらに 53.7% 減少した。Node 上の処理時間はブラウザーの TBT を表すものではない。

結果は `results/slow-network/round2-geometry.json`、画面の前後測定は `round2-before.json` と `round2-after.json` に保存した。

### 画面全体の追加改善前後

同じ Chromium・新しいコンテキスト・下り 1,600 Kbps・上り 750 Kbps・遅延 150 ms で、追加変更の前後をそれぞれ 90 秒測定した。Lighthouse のスコアを再計算した値ではない。

| 指標 | 今回の追加改善前 | 今回の追加改善後 |
| --- | ---: | ---: |
| 完了したリクエストの総転送量 | 4,726,113 B | 3,287,037 B |
| 静的地理データ 5 ファイルの転送量 | 1,621,429 B | 1,311,737 B |
| FCP | 2.232 s | 1.092 s |
| LCP | 5.228 s | 2.656 s |
| Timeline の件数表示 | 3.168 s | 1.568 s |
| Earthquakes の件数表示 | 5.244 s | 2.645 s |
| Hazards の件数表示 | 25.693 s | 18.191 s |
| Alerts の件数表示 | 10.039 s | 9.443 s |
| 配信元一覧のリクエスト開始 | 2.191 s | 1.078 s |

総転送量はさらに 30.4%、LCP は 49.2% 減少した。地理データと配信元一覧は各 1 回。前後ともページエラー・取得失敗は 0。継続中の SSE は総転送量の集計に含めていない。災害・警報・Timeline はライブデータであり、特に Timeline は測定間で件数・本文が変わっている。座標の削減率と完全一致の検証には、上の同一内容の API 比較も併用する。

ビルド済みの web / matrix_whale を localhost:8180 の配信元に反映し、両コンテナの稼働を確認した。

```sh
# web/app から実行。Node 24 以降。
node scripts/perf/geometry.mjs --out ../../perf/results/slow-network/geometry-new.json
node scripts/perf/network.mjs --out ../../perf/results/slow-network/browser-new.json --seconds 90
```

追加変更後の検証は `pnpm check` でエラー・警告 0、Vitest 311 テスト通過、`make test-core` で使い捨て PostgreSQL による統合テストを含め Gleam 293 テスト通過。地図・警報・ネットワークのブラウザーテストは 16 件すべて通過した。

[Google の符号化仕様](https://developers.google.com/maps/documentation/utilities/polylinealgorithm)の整数差分と可変長符号を基に、経度・緯度の順序、精度メタデータ、64 bit 整数を扱える演算を明示した。一般的な固定小数 5 桁への丸めではなく、元の数値が完全に復元される精度を検証してから送信する。[PostGIS の仕様](https://postgis.net/docs/ST_AsGeoJSON.html)では `ST_AsGeoJSON` の既定精度は 9 桁であり、座標桁数だけを切り詰める対応は採用していない。
