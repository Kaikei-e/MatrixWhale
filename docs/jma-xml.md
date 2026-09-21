# 気象庁 防災情報XML (PULL型) 連携仕様・運用ガイドライン

確認日: **2026年9月21日**  
管轄組織: 気象庁 (Japan Meteorological Agency / JMA)

---

## 1. 一次情報出典・利用規約・法的制約

MatrixWhale は、気象庁が公表する「気象庁防災情報XMLフォーマット（PULL型）」を取り込みます。

### 一次情報リンク
- **情報の取得方法 (PULL型)**: [https://xml.kishou.go.jp/xmlpull.html](https://xml.kishou.go.jp/xmlpull.html)
- **気象庁ホームページ利用規約**: [https://www.jma.go.jp/jma/kishou/info/coment.html](https://www.jma.go.jp/jma/kishou/info/coment.html)
- **XML形式電文のご利用にあたっての留意事項 (PDF)**: [https://xml.kishou.go.jp/considerationforxml.pdf](https://xml.kishou.go.jp/considerationforxml.pdf) (令和2年9月1日改訂)
- **気象業務法**: [第17条（予報業務の許可）](https://www.jma.go.jp/jma/kishou/info/ml-17.html) / [第23条（警報の制限）](https://www.jma.go.jp/jma/kishou/info/ml-23.html)

### 利用条件・編集責任・法規遵守
- **公共データ利用規約（第1.0版）準拠**: 出典（例: `出典：気象庁防災情報XMLフォーマット`）を明記します（ロゴ・キャラクターは除外）。
- **編集責任の明示**: 電文を加工・編集して流通させる際は、留意事項に基づき「**公開XML電文が独自に編集されていること、及びその編集責任が編集者にあること**」を利用者に明示します。
- **気象業務法の遵守**:
  - **第23条（警報の制限）**: 気象警報は気象庁の発表内容を忠実に伝達し、本質を損なう改変を行いません。
  - **第17条（予報業務の許可）**: 独自に予想値を算出して発表する行為は行わず、気象庁の発表値の忠実な伝達・正規化に限定します。
- **配信品質とEEW非対応**: PULL型のため配信遅延や欠測が生じる可能性があり、上限時間は保証されません。**緊急地震速報（EEW）のような即時用途には非対応**であり、SLA保証はありません。

---

## 2. 公表仕様（事実） vs 運用の設計選択（自主基準）

| 項目 | 気象庁公表仕様・規約（事実） | MatrixWhale の運用設計（選択肢） |
| :--- | :--- | :--- |
| **IP遮断基準** | 1日10GB以上のダウンロード超過でアクセス元IPを遮断。 | 自主安全上限を **1日最大1GiB**（`JMA_DAILY_BYTE_LIMIT=1073741824`、公表値の約11%）とし、超過時は当日の電文取得を停止（アダプター側で1GiBを超える設定を不許可）。 |
| **フィード巡回** | 高頻度は毎分更新（直近約10分入電保持）、長期は毎時更新（数日間保持）。※PUSH型は令和2年9月1日終了。 | 高頻度は最短1分（`JMA_POLL_INTERVAL=1m`）、長期は最短1時間（`JMA_LONG_POLL_INTERVAL=1h`）を下限値として強制。 |
| **電文取得間隔** | 明示的規定なし | 電文取得間に最低1.0秒（`JMA_REQUEST_INTERVAL=1s`）のスリープを設定。 |
| **単一電文長上限**| 明示的規定なし | 単一電文を最大8MiB（`JMA_MAX_ITEM_BYTES=8388608`）で制限。 |
| **HTTP最適化** | 明示的規定なし | `If-Modified-Since` / `ETag` による 304 活用、サーバー指示の `Retry-After` を永続化して順守。 |
| **実行構成** | 遮断はアクセス元IPアドレス単位 | 同一パブリックIP下での実行は単一インスタンスに限定。 |

---

## 3. 現行の対応範囲と正規化仕様 (Current Scope)

現行パーサーが解釈・正規化する電文は以下に限定されます。

- **地震情報**:
  - `VXSE52`（震源に関する情報）および `VXSE53`（震源・震度に関する情報）を解釈。
  - 有効な震源座標（緯度・経度）が存在する場合のみ `sea.earthquake` にポイントとして正規化。
- **気象警報・注意報**:
  - H27方式市町村気象警報・注意報（`VPWW53` / `VPWW54`）を解釈。
  - 複数警報種別の階層・現象キーを保持し、解除マーク（`cleared_areas`）を考慮して `sea.alert` に正規化。
- **ポリゴン境界マッピング**:
  - **市町村・地域の境界ポリゴン化は未対応**です。地域名（`area_name`）および気象庁地域コード（`geocode`）を保持し、ジオメトリ（`geom`）は `null` とします。
- **訓練・試験・未対応電文の扱い**:
  - `status` が「訓練」または「試験」の電文は、実発報テーブルに反映せずアーカイブのみ行います。
  - R06集約報、津波警報、火山情報等の未対応電文は、生XMLとして `sea.jma_message` に保管され、正規化テーブルへの反映はスキップされます。

---

## 4. データベース構成と状態管理

- **データベーステーブル**:
  - `sea.jma_item`: フィード電文URL、状態（pending/ingested/terminal）、端末パースエラー時の生XMLを保持。
  - `sea.jma_message`: 有効な電文のアーカイブ（ヘッダーメタデータおよび生XML）。
  - `sea.jma_series`: 電文系列（series_key）ごとの最新発表時刻・取消ウォーターマーク。
- **永続ステートとスプール**:
  - アダプターは `JMA_STATE_DIR=/var/lib/jma` 配下に取得履歴（URLログ）、未送信スプール（`spool/`）、HTTPキャッシュ検証値、当日消費バイト数を fsync で記録します。
  - プロセスロック（`jma.lock`）により同一ディレクトリの二重起動を抑止します。
- **異常時境界**:
  - 重複排除は永続ステートに依存します。ボリューム喪失時やファイル未同期のクラッシュ時には同一電文が再取得される可能性があります。

---

## 5. デプロイ手順と運用上の注意

### セットアップ手順
1. **DBマイグレーションの適用**:
   ```bash
   make db-apply
   ```
2. **環境変数の確認**:
   `.envTemplate` の `JMA_CONTACT_EMAIL` に連絡先メールアドレスを設定（推奨）。
3. **関連サービスのビルドと起動**:
   新設ルート・ソース定義・出典表記UIを反映するため、`matrix_whale`、`web`、および `jma_adapter` を再ビルド・再作成します。
   ```bash
   docker compose build matrix_whale web jma_adapter && docker compose up -d matrix_whale web jma_adapter
   ```

### 運用上の警告
- **`jma_state` ボリュームの維持**: Dockerボリューム `jma_state`（`/var/lib/jma`）を不用意に削除しないでください。削除すると取得履歴が消失し、起動時に長期フィードから数日分の電文を全件再取得して帯域予算を圧迫します。
- **全件バックフィルの反復禁止**: 長期フィード（`_l.xml`）の過剰な再取得は避け、定常運用時は高頻度フィードの差分巡回に委ねてください。

---

## 6. 環境変数一覧

| 環境変数名 | デフォルト値 | 説明 |
| :--- | :--- | :--- |
| `JMA_FEEDS` | `https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml,https://www.data.jma.go.jp/developer/xml/feed/extra.xml` | 高頻度フィード完全URL（カンマ区切り）。 |
| `JMA_LONG_FEEDS` | `https://www.data.jma.go.jp/developer/xml/feed/eqvol_l.xml,https://www.data.jma.go.jp/developer/xml/feed/extra_l.xml` | 長期フィード完全URL（カンマ区切り）。 |
| `JMA_STATE_DIR` | `/var/lib/jma` | 永続ステートディレクトリ（Docker永続ボリューム必須）。 |
| `JMA_CONTACT_EMAIL` | *(未設定可・設定推奨)* | User-Agent ヘッダーに付与する連絡先。 |
| `JMA_POLL_INTERVAL` | `1m` | 高頻度巡回間隔（最短1分）。 |
| `JMA_LONG_POLL_INTERVAL`| `1h` | 長期巡回間隔（最短1時間）。 |
| `JMA_REQUEST_INTERVAL` | `1s` | 個別電文取得間の最小ウェイト。 |
| `JMA_DAILY_BYTE_LIMIT` | `1073741824` (1GiB) | 自主的な1日あたり最大ダウンロード制限（公表10GBの約11%）。上限は1GiBに強制。 |
| `JMA_MAX_ITEM_BYTES` | `8388608` (8MiB) | 単一電文許容上限サイズ。 |
