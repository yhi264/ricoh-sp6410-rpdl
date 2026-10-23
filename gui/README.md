# SP 6410 を macOS の印刷ダイアログ（⌘P）から使う

`sp6410` スクリプトは「PDF を作ってからコマンドで流す」方式でしたが、
こちらは **通常のプリンターキューとして登録**する方式です。
どのアプリからでも ⌘P → SP6410 で印刷できます。

## 仕組み

```
アプリ ──⌘P──▶ CUPS ──application/pdf──▶ pdftorpdl ──RPDL──▶ usb バックエンド ──▶ SP 6410
                          ↑                    ↑
                    自前の PPD          中で gs -sDEVICE=rpdl
```

macOS の印刷系は PDF ベースなので、PPD に

```
*cupsFilter: "application/pdf 0 /Library/Printers/RICOH-RPDL/filter/pdftorpdl"
```

と書いておけば、CUPS はジョブの PDF をそのままこのフィルターに渡します。
フィルターが RPDL バイト列を標準出力に吐き、あとは Apple 純正の `usb`
バックエンドが USB に流す。**raw キューも sudo も要りません。**

SIP で保護された `/usr/libexec/cups/filter/` には書き込めませんが、
`*cupsFilter` は**絶対パス**を書けるので、サードパーティドライバーが昔から使っている
`/Library/Printers/<ベンダー名>/` に置きます。

## インストール

```bash
sudo ./install-gui-queue.sh
```

やっていること:

1. gs 本体・依存 dylib・Resource ツリーを `/Library/Printers/RICOH-RPDL/` に同梱
   （`dylibbundler` で収集し `install_name` を `@executable_path/../lib` に書き換え）
2. 全 dylib と gs に **ad-hoc 署名を付け直す**（Apple Silicon では Mach-O を書き換えると
   署名が壊れ `Killed: 9` になる）
3. フィルターと PPD を設置（`root:wheel`、755/644）
4. **gs と Resource の実パスをフィルターに焼き込む** — フィルターは `_lp` ユーザーで走り
   PATH が最小限なので、`gs` を名前で呼んでも見つからない
5. `com.apple.quarantine` を剥がす
6. `lpinfo -v` から USB の URI を拾って `lpadmin` でキュー作成

環境変数で上書きできます: `SP6410_GS` / `SP6410_URI` / `SP6410_QUEUE_NAME`

## 印刷ダイアログで選べる設定

| 項目 | 選択肢 |
|---|---|
| 用紙サイズ | A4 / A3 / A5 / B4(JIS) / B5(JIS) / Letter / Legal |
| 解像度 | 600dpi（既定）/ 400dpi / 240dpi |
| 両面 | しない / 長辺とじ / 短辺とじ |
| 部数 | 印刷ダイアログの部数指定（フィルター側で複製） |

B4/B5 は **JIS** を指定しています。Ghostscript の `b4` は ISO B4 (709×1001pt) で、
RPDL デバイスが JIS B4 (729×1032pt) として認識してくれないため、
フィルター内で `jisb4` / `jisb5` にマップしています。

## 検証済み・未検証

| 項目 | 状態 |
|---|---|
| **⌘P からの印刷** | ✅ **実機で動作確認済み** |
| macOS 26 が PPD 指定のキュー作成を許すか | ✅ 通った（raw キューは拒否されるが PPD は通る） |
| cupsd のサンドボックスが `/Library/Printers/` 下のフィルター実行を許すか | ✅ 通った |
| cupsd のサンドボックスが `/opt/homebrew` の dylib 読み込みを許すか | ❌ **拒否される** → 同梱で回避 |
| フィルター単体の動作（ファイル入力・標準入力・部数複製・PPD デフォルトへのフォールバック） | ✅ 実測 |
| A3 / B4 指定 → 対応する用紙コマンドが出る | ✅ 実測 |
| 両面指定 → `ESC DC2 61,` + `YA01,2` が最初のラスタ直前に入る | ✅ 実測。実機で両面に刷れることも確認済み |
| PPD の構造（PageSize/ImageableArea/PaperDimension の整合、OpenUI 対応） | ✅ チェック済み |

残る未検証は A3 の実出力です。`sp6410` スクリプト方式とは併存できます。

## うまく行かないとき

```bash
sudo cupsctl --debug-logging
lp -d SP6410 テスト.pdf
tail -f /private/var/log/cups/error_log | grep -i rpdl
sudo cupsctl --no-debug-logging
```

フィルターは進捗を `DEBUG: pdftorpdl: ...` の形で stderr に出すので、
どこまで進んだかが error_log で追えます。

| 症状 | 見るところ |
|---|---|
| `lpadmin` が PPD を拒否 | PPD の書式。エラーメッセージをそのまま送ってください |
| 「フィルターに失敗しました」 | error_log。`gs` のパス・権限・サンドボックス拒否のいずれか |
| ジョブは消えるが何も出ない | フィルターは通ったがバックエンドで詰まった。プリンター側の優先エミュレーション設定 |
| 白紙が出る | gs は動いたがラスタが空。error_log の `gs:` 行を確認 |

## アンインストール

```bash
sudo lpadmin -x SP6410
sudo rm -rf /Library/Printers/RICOH-RPDL
```
