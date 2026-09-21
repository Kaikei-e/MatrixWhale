# JMA XML Test Fixtures Provenance & Licensing

## 1. Official Sources & Attribution
The test fixtures in this directory are based on the official Japan Meteorological Agency (JMA / 気象庁) Disaster Prevention Information XML format (気象庁防災情報XMLフォーマット):
- Portal: [https://xml.kishou.go.jp/](https://xml.kishou.go.jp/)
- PULL Guide: [https://xml.kishou.go.jp/xmlpull.html](https://xml.kishou.go.jp/xmlpull.html)
- Terms of Use: [https://www.jma.go.jp/jma/kishou/info/coment.html](https://www.jma.go.jp/jma/kishou/info/coment.html) (公共データ利用規約 第1.0版 / CC BY 4.0 互換)

## 2. Fixture Catalog & Original URLs
1. `vpww54_weather.xml`:
   - Bulletin: 気象警報・注意報（Ｈ２７）（水戸地方気象台 発表）
   - Original URL: `https://www.data.jma.go.jp/developer/xml/data/20260920164632_0_VPWW54_080000.xml`
   - Content: Meteorological warning containing multi-tier Warning elements, status transitions (`発表`, `継続`, `警報から注意報`, `解除`), and area no-warning marker (`発表警報・注意報はなし`).
2. `vxse53_earthquake.xml`:
   - Bulletin: 震源・震度に関する情報（VXSE53、大阪管区気象台 発表）
   - Original URL: `https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml`
   - Content: Observed earthquake bulletin with ISO 6709 coordinates, magnitude, and seismic intensity.

## 3. Editing and Processing Statement (加工・編集責任の表示)
気象庁防災情報XMLをもとにMatrixWhaleがテスト用に抜粋・加工。編集責任：MatrixWhale。
These fixtures have been curated and excerpted by MatrixWhale for unit and conformance testing.
