# ricoh-sp6410-rpdl

RICOH SP 6410 を、オプションの PostScript3 カードなしで macOS から使うための CUPS フィルターと PPD です。Ghostscript の `rpdl` デバイスで PDF を RPDL に変換し、USB で送ります。インストールすると、どのアプリからでも ⌘P で印刷できます。

*A CUPS filter and PPD that let macOS print to a RICOH SP 6410 without the optional PostScript card, by converting PDF to RPDL (one of the printer's built-in languages) with Ghostscript's `rpdl` device.*

## 仕組み

```
アプリ ─⌘P→ CUPS ─PDF→ pdftorpdl（中で gs -sDEVICE=rpdl）─RPDL→ usb バックエンド → SP 6410
```

SP 6410 が標準で理解する言語は RPCS と RPDL です。RPCS 用の Mac ドライバーはなく、リコーの案内では Mac から使うには PostScript3 カード（定価 65,000 円）が要ります。一方の RPDL は、Ghostscript の `rpdl` デバイスで作れます。プリンターも USB の Device ID で `CMD:PJL,RCS,R00` と申告しており、`R00` が RPDL を指します。

解説記事（note）: [6 万 5 千円の PostScript カードを買わずに、RICOH SP 6410 を Mac から使えるようにした話](https://note.com/y_h5977/n/nf778777c1c8d)

PPD の `*cupsFilter` に絶対パスでフィルターを指定してあるので、SIP で守られた `/usr/libexec/cups/filter/` には触りません。raw キューも使いません（macOS 26 では作れません）。

## 必要なもの

- macOS（macOS 26 / Apple Silicon で動作確認）
- USB-B ケーブル（M4 MacBook Pro なら USB-C ↔ USB-B）
- **`rpdl` デバイス入りの Ghostscript**（下記）
- `dylibbundler`（`brew install dylibbundler`）

### Ghostscript について（重要）

`rpdl` は **Ghostscript 10.08.0 で既定のビルドから外れました**。開発元は、テスターが現れなければ 10.09.0 でソースごと削除すると予告しています（[コミット 272e19ee6f](https://github.com/ArtifexSoftware/ghostpdl/commit/272e19ee6f)）。

- 今の Homebrew（10.08.0）の `brew install ghostscript` には **rpdl が入っていません**
- 10.07.1 までの Ghostscript には入っています
- 10.08.0 は、ビルド時に `rpdl` を名前で指定すれば組み込めます

手元の gs に rpdl があるかは次で確かめられます。

```bash
gs -h | tr ' ' '\n' | grep -x rpdl     # "rpdl" と出れば使える
```

出なければ、[docs/build-ghostscript.md](docs/build-ghostscript.md) の手順で自分でビルドしてください。

## プリンター本体の設定

操作パネルで次の 2 つを設定します。工場出荷時の状態に戻すと刷れなくなります。

```
システム設定 → 優先エミュレーション/プログラム → RPDL
システム設定 → エミュレーション検知          → しない
```

## インストール

```bash
git clone https://github.com/yhi264/ricoh-sp6410-rpdl.git
cd ricoh-sp6410-rpdl/gui
sudo ./install-gui-queue.sh
# rpdl 入りの gs が別の場所にあるとき:
sudo SP6410_GS=$HOME/opt/gs-rpdl/bin/gs ./install-gui-queue.sh
```

インストーラーは gs 本体・依存ライブラリ・Resource 一式を `/Library/Printers/RICOH-RPDL/` にコピーし、USB のプリンターを探して `SP6410` というキューを作ります。gs を同梱するのは、cupsd のサンドボックスが `/opt/homebrew` 以下のライブラリの読み込みを拒否するためです。同梱した gs は Homebrew を更新・削除しても動き続けます。

詳しい説明は [gui/README.md](gui/README.md) にあります。

## 印刷ダイアログで選べる項目

- 用紙サイズ：A4、A3、A5、B4（JIS）、B5（JIS）、レター、リーガル
- 解像度：600 dpi（既定）、400 dpi、240 dpi
- 両面：しない、長辺とじ、短辺とじ

## macOS で踏んだ落とし穴

1. **macOS 26 は raw キューを作らせない。** `lpadmin -m raw` は「RAW キューは macOS では現在サポートされていません」で拒否される。PPD ＋ `*cupsFilter` でキューを作る
2. **cupsd のサンドボックスが `/opt/homebrew` の dylib を拒否する。** gs の起動は通るのにライブラリだけ `blocked by sandbox` で弾かれる。gs 一式を `/Library/Printers/` に同梱する
3. **Mach-O を書き換えると Apple Silicon では起動を拒否される。** `dylibbundler` で参照先を書き換えたら、`codesign --force --sign -` で ad-hoc 署名を付け直す。忘れると `Killed: 9`
4. **`gs_init.ps` が見つからない。** Homebrew の gs は `--disable-compile-inits` でビルドされていて、外部の初期化ファイルを読む。Resource ツリーも同梱し、`-I` で場所を教える
5. **PDF を入力すると `-sPAPERSIZE` が無視される。** PDF の MediaBox が優先されるので、`-dFIXEDMEDIA -dFitPage` を付ける
6. **`rpdl` デバイスは `-dDuplex` を無視する。** 出力が 1 バイトも変わらない。最初のラスタ命令 `ESC DC2 "G3"` の直前に両面の命令（`ESC DC2 "61,"` と `ESC DC2 "YA01,2 "`）を自分で差し込む
7. **gs の `b4` は ISO の B4。** JIS の B4 は `jisb4`。rpdl は寸法で用紙を判定するので、ISO のままだと定形外扱いになる

検証の経緯は [docs/verification-log.md](docs/verification-log.md) にあります。

## 実機で確かめたこと

- A4・600 dpi のテキストとラスタ（枠・目盛り・斜線）
- グレーの階調
- 両面印刷。RPDL の命令の仕様は公開されておらず、差し込む命令は Ghostscript の `gdevrpdl.c` から組み立てたもの

## まだ確かめていないこと

- A3 の実出力（データの生成までは確認済み）

## うまくいかないとき

```bash
sudo cupsctl --debug-logging
lp -d SP6410 test.pdf && sleep 3
grep -aE 'pdftorpdl|gs:' /private/var/log/cups/error_log | tail -40
sudo cupsctl --no-debug-logging
```

`rpdl` だけで grep すると gs のエラー行が落ちるので、上の形で絞ってください。

- `Library not loaded ... blocked by sandbox` → 同梱が壊れている。インストーラーを再実行
- `Can't find initialization file gs_init.ps` → フィルターの `GSSHARE=` が実際のコピー先と食い違っている
- `Killed: 9` → ad-hoc 署名が付いていない
- ジョブは消えるが何も出ない → プリンター本体の優先エミュレーションの設定

サンドボックスの外で切り分けるには、フィルターを CUPS と同じユーザーで直接動かします。

```bash
sudo -u _lp /Library/Printers/RICOH-RPDL/filter/pdftorpdl 1 "$USER" test 1 "" test.pdf > /tmp/o.rpdl
```

これが通ってキュー経由で落ちるなら、原因はサンドボックスです。

## コマンドラインで使う

`cli/sp6410` は、キューを作らずに PDF を変換して USB に流すスクリプトです。手順は [docs/cli.md](docs/cli.md) にあります。`tests/smoke-test.rpdl`（126 バイト）は、RPDL への切り替えが効くかだけを確かめるための最小のファイルです。

## アンインストール

```bash
sudo lpadmin -x SP6410
sudo rm -rf /Library/Printers/RICOH-RPDL
```

## ほかの方法

- PCL カード タイプ6400（定価 20,000 円）を挿し、Mac 側は汎用の PCL ドライバーを使う。確実に動く
- Windows の仮想マシンでリコーのドライバーを使う方法は、Apple Silicon の Mac では成り立たない（ARM 版 Windows は ARM 用のプリンタードライバーを要求する）

## 注意

リコーのサポート範囲外の使い方です。このリポジトリには Ghostscript のバイナリを含めていません。Ghostscript は AGPL-3.0 で配布されています。

## ライセンス

MIT（このリポジトリのスクリプトと PPD）
