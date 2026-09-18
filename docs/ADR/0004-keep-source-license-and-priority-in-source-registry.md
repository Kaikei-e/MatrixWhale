---
title: ソースのライセンス・出典・優先度を sea.source マスタで持つ
status: accepted
date: 2026-09-18
depends-on: ["0001"]
---

# 0004: ソースのライセンス・出典・優先度を sea.source マスタで持つ

## コンテキスト

`docs/internal/idea2.md` §6 は「正規化スキーマに、出典とライセンスをレコード単位で持たせる」ことを提案している。動機は、EUMETSAT の Meteosat データのように観測後 3 時間未満は研究・教育・個人利用に限られるといった制限付きソースを、公開 API や UI から自動的に除外できるようにすることである。

実装前の状態は次のとおりだった。

- `domain/earthquake.to_json` が `license: "public-domain"`、`attribution: "U.S. Geological Survey"`、`redistributable: true` を USGS 前提でハードコードしていた。
- `web/app/src/lib/components/EarthquakePanel.svelte` が "Credit: U.S. Geological Survey" という文字列を直接持っていた。
- NOAA と USGS はいずれも米国連邦政府の著作物で public domain だったため、これで支障がなかった。

EMSC を追加する ([[0007]]) と事情が変わる。EMSC のデータは CC BY 4.0 で、出典表示が義務であり、商用の再配布には EMSC/CSEM の書面許可が要る。ソースごとに異なる条件を、表示側の文字列ではなくデータとして扱う必要が生じた。

さらに canonical event の投影 ([[0003]]) ではソース間の優先順位が要る。これも「ソースの属性」であり、同じ場所に置くのが自然である。

ユーザには 3 案 (レコード単位の列 / マスタ + レコード参照 / マスタ + レコード側の `redistributable` だけ override) を示し、「マスタ + レコードは参照のみ」が選ばれた。

## 決定

- Atlas のマイグレーション (`20260917165144_init.sql`) で次の表を追加した。

  ```sql
  CREATE TABLE sea.source (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    homepage TEXT,
    license TEXT NOT NULL,
    attribution_text TEXT NOT NULL,
    redistributable BOOLEAN NOT NULL,
    priority INTEGER NOT NULL
  );
  ```

- レジストリの正本はコードに置く。`src/domain/source.gleam` の `pub const all` に次の 3 件を定義し、`lookup(id)` と `to_json` を提供する。

  | id | name | license | attribution_text | redistributable | priority |
  | --- | --- | --- | --- | --- | --- |
  | noaa | NOAA National Weather Service | public-domain | Source: NOAA National Weather Service | true | 100 |
  | usgs | U.S. Geological Survey | public-domain | Credit: U.S. Geological Survey | true | 100 |
  | emsc | EMSC | CC-BY-4.0 | Credit: EMSC/CSEM, https://www.emsc-csem.org | true | 90 |

- `repository/source_writer.sync` が起動時 (HTTP サーバ起動前) と統合テストのセットアップで全件を upsert する。これは静的データの同期であり、判定ロジックではない。
- レコードはソース ID で参照するだけにする。`sea.earthquake.source` に `sea.source(id)` への FK (マイグレーション `20260917173206_earthquake_source_fk.sql`)、`sea.event.preferred_source` にも同じ FK を張った。
- `GET /api/v1/sources` がレジストリ全件を返す。`domain/earthquake.to_json` の `license` / `attribution` / `redistributable` はレジストリから引く。
- Web は `/api/v1/sources` を一度取得し、選択中のイベントに寄与するソースの出典と、画面に載っている全ソースの出典 (優先度降順の常時表示フッター) を `attribution_text` と `homepage` から描画する ([[0005]])。
- 遅延区分でライセンスが変わるソースは、将来 `eumetsat_nrt` / `eumetsat_delayed` のようにソース ID を分けて表現する。レコード単位の例外列は設けない。

## 根拠（調査結果・出典）

- EMSC の利用条件: データセットは CC BY 4.0、個人・学術・教育・非商用研究などでの再配布は可、商用再配布は EMSC/CSEM の書面許可が必要、求められる出典表示は "Credit: EMSC/CSEM, https://www.emsc-csem.org"。https://www.seismicportal.eu/terms.html 。リアルタイム WebSocket 経由のデータも CC BY 4.0 と明記されている。https://www.seismicportal.eu/realtime.html
- USGS と NWS のデータが public domain で出典表示が任意であることは `docs/internal/usgs_pipeline.md` §4.4 と README に記録済みで、今回はその文言 ("Credit: U.S. Geological Survey") をレジストリに移した。
- 出典表示は「表示中のデータに含まれる全ソース」に対して必要になる。CC BY の帰属要件は、そのソースの作品が画面にある限り満たさなければならないためで、選択中のイベントにだけ出す実装では EMSC 由来の点が地図に載っているのに出典が無い状態が生じる。実装ではこの点を追加で修正した (常時表示フッター)。
- `priority` をマスタに置く根拠は [[0003]] の投影規則にある。優先度は「そのソース全体の信頼度」であってレコードの属性ではない。
- 実測: 起動後の `GET /api/v1/sources` は 3 件を返し、`/globe` の EarthquakePanel は USGS と EMSC の両方の出典リンクを描画した (Playwright テストで固定)。

## 検討した代替案

- **レコード単位に `license` / `attribution` / `redistributable` 列を持つ (idea2 の原案)**: 最も柔軟だが、同じソースの全行が同じ値を持つため冗長で、文言変更が全行 UPDATE になる。ライセンスは「データがどこから来たか」で決まり、行ごとに変わるものではない。
- **マスタ + レコード側に nullable な `redistributable` の override**: EUMETSAT の遅延区分のような例外に備える折衷案。今回のソースには例外が無く、例外はソース ID を分ければ表現できるため、列を先回りして増やさない。
- **Atlas のデータマイグレーションでシードする**: 文言や優先度がマイグレーション履歴に固定され、変更のたびにマイグレーションを生成することになる。コードにレジストリを持てば投影ロジックが DB を引かずに優先度を参照でき、テストも純粋関数で書ける。
- **フロントエンドにハードコードし続ける**: ソースが 3 つ以上になると UI と API が別々に文言を持つことになり、`redistributable` によるフィルタ (公開 API から除外する要件) を実装する場所が無い。

## 影響とトレードオフ

- **二重管理**: レジストリはコード (正本) と DB (FK 整合と API のため) の両方にあり、起動時の upsert で同期する。ライセンス文言の変更はコード変更とデプロイを伴う。
- **起動順序**: FK があるため、新しいソースのアダプタが最初の書込をする前に `sync` が済んでいなければならない。`matrix_whale.gleam` はサーバ起動前に `sync` を呼ぶ。
- **レコード単位の例外が表現できない**: 遅延区分のようなケースはソース ID を分けることで対応する。同じ上流を 2 つのソースとして扱うと、[[0003]] の照合で同じ event に両方のメンバーが付く可能性があり、その際の優先度設計が必要になる。
- **`redistributable` によるフィルタは未実装**: 列と API は用意したが、公開 API から `redistributable = false` のソースを除外する処理は、そのようなソースを追加する時点で入れる。
- **出典の表示責任は Web 側**: API は文言を返すだけで、表示を強制しない。別のクライアントを作る場合は `/api/v1/sources` を読んで同じ義務を果たす必要がある。

## 関連ADR

- [[0001]] — `sea.source` と FK は Atlas のマイグレーションとして追加した。
- [[0003]] — `priority` は canonical event の投影規則で使う。
- [[0005]] — Web の出典表示は `/api/v1/sources` を読む。
- [[0007]] — EMSC のレジストリ項目 (CC BY 4.0) を追加した。
