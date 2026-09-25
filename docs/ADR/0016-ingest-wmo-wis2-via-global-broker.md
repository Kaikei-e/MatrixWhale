---
title: WMO WIS2 Global BrokerからMQTTで電文を購読し、CAP警報・熱帯低気圧進路・観測危険値を正規化する
status: accepted
date: 2026-09-25
depends-on: ["0002", "0004", "0006", "0011", "0012"]
---

# 0016: WMO WIS2 Global BrokerからMQTTで電文を購読し、CAP警報・熱帯低気圧進路・観測危険値を正規化する

## コンテキスト

MatrixWhale は、NOAA NWS 警報、USGS / EMSC 地震、GDACS 複数災害、WMO Register of Alerting Authorities（RAA）に基づく各国 CAP 警報、および気象庁（JMA）防災情報 XML などを統合してきた。
世界気象機関（WMO）は従来の GTS から次世代データ交換基盤「WIS 2.0（WMO Information System 2.0）」への移行を進めており、MQTT v5 プロトコルを用いたリアルタイム通知電文（WIS2 Notification Message: WNM）および Global Broker、Global Cache による世界規模の気象データ配信環境を提供している。

MatrixWhale において世界中の公的気象警報、熱帯低気圧の進路予報モデル、および危険域の地上観測データを準リアルタイムで網羅的に捕捉するためには、WIS2 のリアルタイム PUSH 配信網への接続が不可欠である。
一方で、WIS2 連携においては以下の前提条件・制約・満たすべき要件が存在する。

- **接続負荷と信頼性**: 各国の Origin 配信元（WIS2 Node）に過度な負荷を与えず、かつブローカー障害時にも安定して継続受信できる構成が求められる。
- **データ形式の多様性と安全性**: CAP（XML 形式）や BUFR4（バイナリ形式）など異なる形式が混在する。特に外部から受け取る非信頼の XML 電文を BEAM VM 上でパースする際のアトムテーブル枯渇リスクを回避しなければならない。
- **既存データモデルとの統合と重複排除**: 既に [[0012]] で稼働している WMO RAA 由来の CAP パイプラインとの重複排除、および GDACS の熱帯低気圧（TC）モデルとの整合性を保つ必要がある。
- **運用性とライセンス**: アダプターサービスの軽量性、オープンソースライセンスの適合性、および監視可能性を担保する必要がある。

## 決定

1. **Go サービス `wis2_adapter` の新設と単一 Global Broker 接続・フェイルオーバー**:
   - `adapters/common` を活用した新規 Go アダプター `wis2_adapter` を導入する。
   - 単一の WIS2 Global Broker に対し MQTT v5 / TLS で接続し（公開認証情報 `everyone` / `everyone`、`CleanStart = true`、一意なクライアント ID を生成）、常時購読する。
   - 接続障害時は、以下の優先順序でフォールバック（フェイルオーバー）を試行する。
     1. Météo-France（`mqtts://globalbroker.meteo.fr:8883`）
     2. CMA / 中国気象局（`mqtts://gb.wis.cma.cn:8883`）
     3. NOAA/NWS（`mqtts://wis2globalbroker.nws.noaa.gov:8883`）
     4. INMET / ブラジル国立気象局（`mqtts://globalbroker.inmet.gov.br:8883`）

2. **Global Cache トピックへの限定購読と完全性検証**:
   - 購読トピックは Global Cache 配信経路（`cache/a/wis2/...`）のみとし、Origin 経路（`origin/a/wis2/...`）は直接購読しない。
   - WNM の `properties.content` にインラインデータが含まれる場合はそれを直接使用する。
   - インラインデータがない場合は Global Cache の標準リンク（`links[rel=canonical]`）からダウンロードし、失敗時は他リンクまたは Origin リンクへフォールバックする。
   - WNM に `properties.integrity`（`sha512` または `sha3-512`）が存在する場合は、ダウンロードしたペイロードのハッシュ検証を行う。

3. **取り込みスコープと BUFR4 デコード**:
   - 取り込み対象は以下の3種類に限定する。
     - **CAP 警報**: 気象警報・注意報トピック（`.../data/core/weather/advisories-warnings`）
     - **熱帯低気圧決定論的進路予報**: BUFR trajectory トピック（`.../data/core/weather/prediction/forecast/+/+/trajectory`）
     - **危険レベルの地上観測値**: BUFR SYNOP トピック（`.../data/core/weather/surface-based-observations/synop`）
   - SYNOP 観測値の危険判定（閾値判定）は Gleam コア側で実施し、閾値未満の通常観測値（非危険値）は破棄する。
   - BUFR4 バイナリのデコードは、WMO 公式 BUFR4 テーブルを vendor 保持した内製の pure-Go デコーダーで行う。
   - ※BUFR デコーダーの詳細仕様、熱帯低気圧進路予報および地上観測値の正規化・閾値判定ロジックについては、将来の個別 ADR で策定する。

4. **Go 側での共通 CAP XML パースと安全な JSON 転送**:
   - CAP XML は BEAM コア内ではパースせず、Go 側で共通パーサー（`adapters/common/cap`、`cap_adapter` と共用）を用いて解析し、コアへは正規化された JSON を POST する。
   - BEAM の `xmerl` で非信頼の外部 XML を解析すると動的にアトムが生成され、アトムテーブル枯渇（Atom table exhaustion）による VM クラッシュのリスクがあるため、コア内 XML パースを禁止する。

5. **RAA パイプラインとの CAP 重複排除および Meteoalarm ジオメトリ結合**:
   - `sea.cap_message` 内で `(sender, identifier)` を主キーとして [[0012]] の RAA パイプラインと重複排除を行う。
   - Meteoalarm（センター ID: `eu-eumetnet-warnings`）はエリア単位で通知を送信し、期限付き署名付き URL（`links[rel=geometry]` の GeoJSON）を付与する。アダプターはこれを即時ダウンロードし、CAP 本文にポリゴンや円が存在しない場合、コアが全エリアの GeoJSON を集約してアラートジオメトリを組み立てる。
   - 同一 CAP が先行して RAA パイプライン経由で取り込まれジオメトリが未設定であった場合でも、WIS2 側のエリア GeoJSON により同一アラートのジオメトリを補完・更新する。

6. **データソース定義・優先度・熱帯低気圧の統合**:
   - 発行センター（centre）ごとに `sea.source` レコードを1件登録する（ID: `wis2-<centre-id>`）。
   - CAP 警報の優先度は 70（RAA 経由警報と同等水準）とする。
   - 熱帯低気圧（TC）進路予報の優先度は 75（モデル予報値として、GDACS 実況値の 80 より低位）とし、正準イベント（canonical events）を介して GDACS TC と突合・照合した上で、GDACS TC の詳細パネル内にモデル進路予報として重畳表示する。

7. **障害復旧後のギャップ補完（Gap fill）方針**:
   - アダプター停止・障害復旧後の過去データ補完は、警報（warnings）および熱帯低気圧（TC）のみを対象とし、Global Cache のスキャンが実行可能な範囲で実施する。
   - データ量が膨大かつ即時観測が主である SYNOP については、ダウンタイム中の欠測ギャップを許容する。

8. **MQTT ライブラリ選定とライセンス適合性**:
   - MQTT v5 クライアントとして `github.com/eclipse/paho.golang` を使用する。
   - 本ライブラリのデュアルライセンス（EPL-2.0 / EDL-1.0）のうち、Eclipse Distribution License 1.0（BSD-3-Clause 相当）を選択・適用し、当リポジトリの Apache-2.0 ライセンスとの互換性を確保する。

9. **ヘルス監視と UI 統合**:
   - アダプターは `(centre, kind)` ごとの送受信カウンターを 60 秒周期でコアへ報告する。
   - コアは 1 時間単位のバケット（`sea.wis2_health_bucket`）に集計・保存する。
   - `/feeds` ページに WIS2 専用セクションを追加し、ブローカー接続状況（`sea.wis2_broker`）およびセンター別ヘルス状況を表示する。
   - WIS2 経由の CAP 警報は既存の「Alerts」タブに統合表示し、専用の新規タブは作成しない。

## 根拠（調査結果・出典）

- **2026-09-25 実機プローブ調査結果（定性的事実）**:
  - ※公開リポジトリの特性に鑑み、具体的な数値・転送レート・計測件数は記載せず、定性的な事実関係のみを記録する。
  - Météo-France の Global Broker は、公開アカウント `everyone` / `everyone` による QoS 1 での購読要求を正常に受理した。
  - 短時間の観測窓において、気象警報（advisories-warnings）を実際に発行していたセンターは `eu-eumetnet-warnings`（Meteoalarm）のみであった。
  - 受信電文の大部分（大半のトラフィック）は SYNOP 地上観測データで占められており、その大部分は WNM の `properties.content` 内にインラインで格納されていた。
  - 熱帯低気圧（TC）進路予報はモデル計算サイクル（バッチ実行）単位で発行されるため、短時間の観測窓では入電が確認されなかった。
  - 電文の完全性検証方式として `sha512` および `sha3-512` の双方が実際に配信されていることを確認した。
  - Meteoalarm（`eu-eumetnet-warnings`）の通知メッセージには `integrity` フィールドが付与されておらず、外部リンクには有効期限（Expires）が設定された署名付き URL（pre-signed URL）が使用されていることを確認した。

- **一次情報出典**:
  - WMO WIS2 総合ガイド: [https://github.com/wmo-im/wis2-guide](https://github.com/wmo-im/wis2-guide)
  - WMO WIS2 トピック階層体系仕様: [https://github.com/wmo-im/wis2-topic-hierarchy](https://github.com/wmo-im/wis2-topic-hierarchy)
  - WMO WIS2 Notification Message (WNM) 仕様: [https://github.com/wmo-im/wis2-notification-message](https://github.com/wmo-im/wis2-notification-message)
  - WMO BUFR4 仕様およびテーブル定義: [https://github.com/wmo-im/BUFR4](https://github.com/wmo-im/BUFR4)
  - Eclipse Paho MQTT Go クライアント: [https://github.com/eclipse/paho.golang](https://github.com/eclipse/paho.golang)
  - WMO WIS2 Global Services 概要: [https://community.wmo.int/en/activity-areas/wis/wis2-global-services](https://community.wmo.int/en/activity-areas/wis/wis2-global-services)

## 検討した代替案

- **複数ブローカーへの並行購読（parallel subscription to multiple brokers）**:
  - 不採用。各 Global Broker は相互同期されているため、並行購読すると同一メッセージが重複して大量に届き、ネットワーク帯域およびアダプターの重複排除処理負荷が激増する。通常時は単一ブローカーに接続し、障害時にフォールバックする構成で十分な耐障害性を得られる。
- **Origin チャネルの購読（origin channel）**:
  - 不採用。Origin チャネルの購読は各国の配信元ノード（WIS2 Node）に直接リクエストを集中させるリスクがあり、WIS2 アーキテクチャの基本設計に反する。CDN キャッシュと安定した高速配信を提供する Global Cache チャネルを原則とする。
- **コア主導のダウンロード待機キュー（core-driven pending download）**:
  - 不採用。CAP RAA や GDACS のようにアダプターとコア間で pending キューをポーリングする方式は、リアルタイム PUSH 型の MQTT ストリーミングにおいて不要な遅延と往復通信を生じさせる。また Meteoalarm のジオメトリ URL には有効期限があり、キューを介すと期限切れになる恐れがあるため、アダプターによる即時ダウンロードを採用した。
- **cgo 経由での ecCodes 利用（ecCodes via cgo）**:
  - 不採用。ECMWF の ecCodes は C 言語実装であり、cgo 呼び出しによるオーバーヘッド、クロスコンパイル環境の複雑化、および C 側の異常終了が Go プロセス全体を巻き込むリスクがある。ポータビリティと安全性を優先し、WMO 公式テーブルを内包した pure-Go デコーダーを自作する。
- **Python サイドカーによるデコード（Python sidecar）**:
  - 不採用。別コンテナ・言語ランタイムの運用保守、およびプロセス間通信（IPC）のオーバーヘッドが生じる。高スループットが要求される SYNOP 観測値の処理においてレイテンシとリソース消費が増大するため、Go 単一バイナリによる処理を選択した。
- **BEAM コア内での xmerl による CAP パース（parsing CAP in the core with xmerl）**:
  - 不採用。Erlang 標準の `xmerl` で信頼性の保証されない外部 XML を解析すると、要素名や属性名が動的にアトム（Atom）として生成される。アトムは GC（ガベージコレクション）されないため、悪意ある電文や大量の異なるタグによりアトムテーブルの上限（デフォルト約104万）に達し、BEAM VM 全体がクラッシュ（Atom table exhaustion）する致命的脆弱性となる。そのため Go 側で安全に JSON へ変換してからコアへ渡す。
- **独立した専用 WIS2 タブの新設（a dedicated WIS2 tab）**:
  - 不採用。ユーザーにとって WIS2 はプロトコルやインフラの違いにすぎず、情報の実態は「警報（Alerts）」や「熱帯低気圧（Hazards）」である。プロトコル単位でタブを乱立させると UI の一覧性・俯瞰性が損なわれるため、既存の Alerts タブおよび Hazards の GDACS TC 詳細へ自然に統合する。

## 影響とトレードオフ

- **得るもの**:
  - 世界規模の気象警報、熱帯低気圧モデル進路、および危険気象観測値を、低遅延かつ高効率な MQTT v5 PUSH 配信でリアルタイム取得できる。
  - Pure-Go BUFR4 デコーダーと Go 側 XML パースにより、BEAM コアの堅牢性（アトムテーブル保護）とコンテナ環境の軽量・安全性を両立できる。
  - Meteoalarm ジオメトリの自動結合により、ポリゴンを持たない CAP 警報の地図可視化が実現される。
  - 4大 Global Broker 間の自動フェイルオーバーにより、単一ブローカー障害時でも継続運用が可能となる。
- **失うもの・引き受けるリスク**:
  - 障害復旧時のギャップ補完において、SYNOP 観測値の欠測を受け入れる（警報および TC のみ補完対象）。
  - Meteoalarm の pre-signed URL には有効期限が存在するため、アダプター側のネットワーク障害等で即時ダウンロードに失敗した場合、後からのジオメトリ再取得が困難になる。
  - Pure-Go BUFR4 デコーダーの内製に伴う初期実装・検証コスト（後続 ADR で対応）。

## 関連ADR

- [[0002]]: Gleamインテークパイプラインでのリビジョン判定
- [[0004]]: `sea.source` マスタでのライセンス・出典・優先度保持
- [[0006]]: `adapters/common` による共通HTTPクライアント・バックオフ
- [[0011]]: `sea.alert` テーブルの多ソース化とCAP正規化
- [[0012]]: WMO Register of Alerting Authorities (RAA) パイプラインによるCAP電文収集
