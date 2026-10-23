# 検証ログ — 何をどう確かめたか

結論に至る根拠の記録。「なぜそう言えるのか」を後から辿れるようにしたもの。
推測は推測と明記してある。

---

## 1. 前提の確認

### SP 6410 の標準搭載言語

リコー公式仕様および使用説明書「本体の仕様」より、5 機種共通で:

```
標準        RPCS、RPDL
オプション  Adobe PostScript 3、PDF、PCL（PCL XL/PCL 5e）、RP-GL/2、RP-GL、
            R16、R55（IBM5577）、R98、RTIFF、XPS
```

SP 6410 だけ言語が少ないという記載はない。HDD とメモリー、操作部（6440 のみタッチパネル）に
機種差があるだけ。

### Mac 純正ルートは PS3 必須

- 仕様表: 「Mac OS X 10.9 以降はオプション対応」
- 使用説明書「USB（Bコネクター）インターフェースに接続する」: Macintosh 使用には PS3 カードが必要
- リコー FAQ: 「Mac から印刷できない場合に PostScript モジュール (PS3) が装着されているかを確認する方法」

RPCS/RPDL の Mac 用ドライバーは存在しない。

### 言語切り替えの設定

使用説明書 `/manual/int/0253.htm`（SP 6450/6430/6420/6410 のシステム設定）:

| 項目 | 選択肢 | 工場出荷時 |
|---|---|---|
| エミュレーション検知 | する、しない | する |
| 優先エミュレーション/プログラム | RPCS、**RPDL**、R98、R16、R55、RPGL、RTIFF、PCL、PCLXL、PS3、PDF、XPS、プログラム1〜16 | RPCS |

`/manual/int/0623.htm`（エミュレーション検知）より:
- 自動判別の対象は「PS3、PDF、R16、R55、RTIFF、RP-GL/GL2、**RPDL**、PCL、XPS」
- **RPCS は自動判別の対象外**（優先エミュレーション設定でしか選ばれない）
- **エミュレーション切り替えコマンドを受信したときはそちらが優先**

最後の 1 行が効いた。Ghostscript は出力先頭で切り替えコマンドを吐く。

---

## 2. Ghostscript 側

### rpdl デバイスの実在確認

Debian の Ghostscript 10.02.1 で実測:

```
$ gs -h | tr ' ' '\n' | grep -E '^(rpdl|npdl|lips[0-9a-z]*|escpage)$' | sort -u
escpage
lips2p
lips3
lips4
lips4v
npdl
rpdl
```

### ソース確認 (`contrib/japanese/gdevrpdl.c`, 305 行)

- 対応解像度: **240 / 400 / 600 dpi のみ**（`rpdl_open` で他は弾く）
- モノクロ専用（`gdev_prn_initialize_device_procs_mono`）
- 用紙: A1〜A6、B4〜B6、Letter、Legal、Half Letter、Ledger。該当なしは Free Size (mm) に落ちる
- 用紙判定は **pt 単位の実寸で ±5pt 以内**の一致を見る → JIS/ISO の B 判の違いが効く
- ラスタは `ESC DC2 "G3,..."`、`lips_mode3format_encode` で圧縮。圧縮結果が悪ければ生データ
- 初期化列の先頭が `ESC DC2 "!@R00" ESC SP` = Change to RPDL Mode

### Homebrew の gs に rpdl が入るか

formula（10.07.1）が configure に渡す引数:

```
--disable-compile-inits --disable-cups --disable-gtk
--with-system-libtiff --without-versioned-path --without-x
```

`--with-drivers` も `--disable-contrib` も指定なし。
同じ tarball を同じ引数で configure した結果、生成された Makefile の `DEVICE_DEVS2` に:

```
$(DD)escpage.dev  $(DD)lips4.dev  $(DD)lips4v.dev  $(DD)npdl.dev  $(DD)rpdl.dev
```

configure 既定値 `drivers="ALL"` → `PRINTERS` → `JAPAN_DEVS` の経路で拾われる。

**将来の警告**: ghostpdl master では `JAPAN_DEVS` が
`'ljet4pjl lj4dithp dj505j picty180'` に縮小され、rpdl 等は `JAPAN_CONTRIB_DEVS` に分離。
`ALL` は `PRINTERS,FILES,X11,OCR` にしか展開されないため、**master 系では既定ビルドに rpdl は入らない**。
configure 末尾に deprecated 警告も追加されている。

---

## 3. 実機での検証（時系列）

### smoke test（ラスタなし・126 バイト）

```
ESC DC2 "!@R00" ESC SP  ESC DC2 "YP,2 "  <テキスト>  FF
```

→ **1 枚出力成功。** 言語切り替えが効くことを確認。

同時に、デバイス ID から裏が取れた:

```
CMD:PJL,RCS,R00;
```

`R00` = RPDL。Ghostscript の切り替えコマンドと一致。

### ラスタテストページ（A4 600dpi）

枠・10mm 目盛り・グレースケール・斜線を含むページ → **概ね良好。**
`ESC DC2 "G3"` 形式のラスタが SP 6410 の RPDL パーサで解釈できることを確認。

これで「2002 年実装の rpdl デバイスが 2015 年の機種で通るか」という最大の未確定要素が消えた。

### 送信経路の切り分け

| 経路 | 結果 |
|---|---|
| A: CUPS raw キュー（`lpadmin -m raw`） | ❌ 「RAWキューはmacOSでは現在サポートされていません」 |
| B: `/usr/libexec/cups/backend/usb` 直叩き | ✅ 動作（要 sudo） |
| C: libusb 直書き（`usbsend.py`） | 未検証（B が通ったため） |
| D: PPD + cupsFilter でキュー作成 | ✅ **最終構成** |

### PPD 経路の 3 段階の失敗と解決

1. `dyld: Library not loaded ... (blocked by sandbox)`
   → gs は exec できるが `/opt/homebrew` の dylib を読めない
   → gs 一式を `/Library/Printers/RICOH-RPDL/` に同梱

2. `Can't find initialization file gs_init.ps`
   → 同梱した gs が元 prefix の Resource を探していた
   → Resource ツリーも同梱し `-I` で指定

   （実際にはこの時点でフィルターが古い版のままだったのが原因。
   インストーラーに版ずれ検出のガードを追加した）

3. 成功

### サンドボックス外との比較

```
$ sudo -u _lp /Library/Printers/RICOH-RPDL/filter/pdftorpdl 1 "$USER" test 1 "" /tmp/t.pdf > /tmp/o.rpdl
DEBUG: pdftorpdl: done (569866 bytes x 1)
```

`_lp` 権限では動く → 原因はサンドボックス、と切り分けられた。

---

## 4. コンテナ上で実測したこと

実機に投げる前に Linux コンテナ側で確かめた項目。

### -dDuplex は無視される

```
$ gs ... -dDuplex=true -sOutputFile=d.rpdl test.ps
$ cmp -s d.rpdl test-a4-600.rpdl && echo IDENTICAL
IDENTICAL
```

1 バイトも変わらない。2010 年の実測報告（dayflower）と一致。

注入後の確認:

```
b'... \x1b\x12#4 \x1b\x12D1 \x1b\x12N1 \x1b\x1261,\x1b\x12YA01,2 \x1b\x12G3,4512,32'
                                        ^^^^^^^^^^^^^^^^^^^^^^^^^ 注入した両面コマンド
```

初期化ブロックの直後、最初のラスタコマンドの直前に入ることを確認。

### PDF 入力では -sPAPERSIZE が効かない

```
PageSize=B4 を指定 → 出力された用紙コマンド: A4
```

`-dFIXEDMEDIA -dFitPage` 追加後:

```
PageSize=B4 → B4R    PageSize=A3 → A3R    PageSize=A4 → A4R
```

### フィルター単体テスト

| ケース | 結果 |
|---|---|
| ファイル入力 | ✅ |
| 標準入力 | ✅ |
| 部数 2 → RPDL ヘッダー 2 個 | ✅ |
| オプション空 → PPD の `*Default` へフォールバック | ✅ |
| PageSize=A3 → `ESC DC2 51@A3` | ✅ |
| PageSize=B4 → `ESC DC2 51@B4`（jisb4 マップ） | ✅ |
| Duplex=DuplexTumble → `YA01,1` | ✅ |

### PPD の構造チェック

PageSize / PageRegion / ImageableArea / PaperDimension のキー集合が一致、
OpenUI と CloseUI が 4 対 4、ImageableArea が PaperDimension の内側、
必須キーワードの存在をスクリプトで確認済み。

---

## 5. 検討して捨てた選択肢

| 案 | 却下理由 |
|---|---|
| PCL カード タイプ6400 + Gutenprint | 有効。ただし追加投資が発生するため保険扱い |
| Windows 機を USB で繋いで共有フォルダ自動印刷 | 有効。ただし常時稼働の Windows 機が要る |
| M4 Mac 上の Windows VM + RPCS ドライバー | **不可能**。Windows on ARM は ARM64 ネイティブのプリンタードライバーを要求し、x64 ドライバーはインストールできない。販売終了機に ARM64 版 RPCS が出ることはない |
| Raspberry Pi を RPDL ゲートウェイにして AirPrint 化 | 有効かつエレガント。「Mac 単体で完結させたい」という要件で不採用 |
| `~/Library/PDF Services/` にスクリプトを置いて印刷ダイアログから呼ぶ | **不可能**。Big Sur 以降 `printtool` が強くサンドボックス化され、シェル・Python・署名済みバイナリ・Automator プラグインすべて実行拒否。Full Disk Access も効かない |
| Automator のクイックアクション（Finder 右クリック） | 有効。PPD 経路が通ったので不要になった |
