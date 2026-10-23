# M4 Mac 単体で SP 6410 を RPDL 運用する

Pi も Windows も使わず、MacBook Pro (M4) だけで完結させる構成。
**実機で成立を確認済み**（PS3 カード・PCL カードとも不要）。

> **この文書はコマンドライン版（`sp6410` スクリプト）の手順です。**
> アプリの印刷ダイアログ（⌘P）から使う本番構成は `../gui/README.md` を参照してください。
> 両者は併存できます。

> **2026-10 追記:** Ghostscript 10.08.0 で rpdl は既定のビルドから外れ、Homebrew の
> `brew install ghostscript` では入らなくなりました。下の「関門①」の `brew install` は
> 10.07.1 までの話です。今から用意する場合は [build-ghostscript.md](build-ghostscript.md) を見てください。

## 確定した構成

```
PDF ──gs -sDEVICE=rpdl──▶ RPDL バイト列 ──/usr/libexec/cups/backend/usb──▶ SP 6410
```

| 項目 | 結果 |
|---|---|
| Ghostscript の `rpdl` デバイス | ✅ 動作 |
| `smoke-test.rpdl`（テキストのみ） | ✅ 出力 |
| `test-a4-600.rpdl`（ラスタ） | ✅ 概ね良好 |
| 送信経路 A: CUPS raw キュー | ❌ macOS 26 が拒否 |
| 送信経路 B: CUPS の usb バックエンド直叩き | ✅ **これを使う**（要 sudo） |
| 送信経路 C: libusb 直書き | 未検証（sudo 不要にしたいとき用） |

**裏取り**: プリンターの IEEE 1284 デバイス ID が
`CMD:PJL,RCS,R00;` を申告している。`RCS`=RPCS、**`R00`=RPDL** で、
Ghostscript が先頭に吐く `ESC DC2 !@R00 ESC SP`（Change to RPDL Mode）と一致する。
プリンター自身が RPDL を喋れると宣言していた。

---

## 関門① Ghostscript の `rpdl`

Homebrew の ghostscript formula（現行 10.07.1）を読んで、実際に同じ tarball を
同じ configure 引数で構成してみたところ、生成された Makefile の `DEVICE_DEVS2` に

```
$(DD)escpage.dev  $(DD)lips4.dev  $(DD)lips4v.dev  $(DD)npdl.dev  $(DD)rpdl.dev
```

が入りました。formula は `--disable-contrib` も `--with-drivers` も指定しておらず、
configure の既定値 `drivers="ALL"` から `PRINTERS` → `JAPAN_DEVS` と展開されて
`rpdl` が拾われます。**つまり `brew install ghostscript` で入るはず。**

```bash
brew install ghostscript
gs -h | tr ' ' '\n' | grep -x rpdl        # "rpdl" が出れば OK
```

> ⚠️ **期限つきの話です。** ghostpdl の master では `JAPAN_DEVS` が縮小され、
> `rpdl` は新設の `JAPAN_CONTRIB_DEVS` に分離されて **既定ビルドから外れました**。
> configure の末尾にも「メンテナ／テスターが現れなければ次のリリースで削除する」
> という警告が追加されています。Homebrew が次版に追随した時点で
> `brew install` だけでは入らなくなる可能性が高い（この追随部分は推測）。
> **動くバイナリを手に入れたら `gs` を別名で退避しておくことを勧めます。**

### 入っていなかった場合：自前ビルド

```bash
brew install pkgconf freetype libpng jpeg-turbo libtiff little-cms2 \
             openjpeg jbig2dec fontconfig libidn libarchive leptonica

curl -LO https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/ghostpdl-10.07.1.tar.xz
tar xf ghostpdl-10.07.1.tar.xz && cd ghostpdl-10.07.1

./configure --prefix="$HOME/opt/gs-rpdl" \
            --with-drivers=ALL,rpdl,npdl,escpage,lips4v \
            --disable-cups --disable-gtk --without-x \
            --disable-compile-inits --without-versioned-path
make -j"$(sysctl -n hw.ncpu)" && make install

"$HOME/opt/gs-rpdl/bin/gs" -h | tr ' ' '\n' | grep -x rpdl
```

`--disable-contrib` は**絶対に付けない**（付くと contrib.mak ごと外れる）。
デバイス名を直接並べるのは、未知の語をそのままドライバ名として積む実装なので
新旧どちらの configure でも無害に効きます。

自前ビルドした場合は `export SP6410_GS="$HOME/opt/gs-rpdl/bin/gs"` で `sp6410` から使えます。

---

## 関門② USB への生送信

### Step 0. ケーブル

M4 MacBook Pro は USB-C しかないので、**USB-C ↔ USB-B（プリンター側の角形）** の
ケーブルかアダプターが要ります。ハブ経由でも構いませんが、
切り分け中はできれば直結で。

### Step 1. プリンター側の設定

```
メニュー → システム設定 → 優先エミュレーション/プログラム → RPDL
メニュー → システム設定 → エミュレーション検知        → しない
メニュー → インターフェース設定 → 受信バッファ         → 256KB   （任意）
メニュー → インターフェース設定 → インターフェース切り替え時間 → 60秒（任意）
```

A4 トレイに紙が入っていることを確認。

### Step 2. 送信経路（上から順に試す）

#### 経路 A: CUPS の raw キュー — ❌ **macOS 26 では使えないことを実機で確認**

```
$ sudo lpadmin -p SP6410RAW -E -v 'usb://RICOH/SP%206410%20JPN?serial=...' -m raw
lpadmin: RAWキューはmacOSでは現在サポートされていません。
```

Apple の CUPS 側 issue #5271 は Future のまま未実施でしたが、
**Apple は macOS の lpadmin 側で先に塞いでいました。** 経路 B / C を使ってください。
（`lpinfo -v` でプリンターが `direct usb://RICOH/SP%206410%20JPN?serial=...` として
見えること自体は確認できているので、USB の口は生きています）

<details>
<summary>元の手順（記録用）</summary>

```bash
lpinfo -v | grep usb
# → usb://Ricoh/SP%206410?serial=XXXXXXX のような URI を控える

sudo lpadmin -p SP6410RAW -E -v 'usb://Ricoh/SP%206410?serial=XXXXXXX' -m raw
lpstat -p SP6410RAW

lp -d SP6410RAW -o raw smoke-test.rpdl
```

macOS の CUPS で raw キューが使えるかは事前に断言できませんでしたが、
根拠として: Apple の CUPS リポジトリで「ドライバーと raw キューのサポートを削除する」
という issue (#5271) は **Future マイルストーンのまま未実施でクローズ**、
リポジトリ自体が 2026-03 にアーカイブされています。
つまり macOS が抱えている CUPS 2.x 系では**まだ削除されていない**。
実機で `lpadmin` が弾かれたら経路 B へ。

`-m raw` が通らない場合は Web UI 経由でも作れます:

```bash
sudo cupsctl WebInterface=yes
open http://localhost:631/admin
# Add Printer → USB のプリンターを選択 → Make: Raw → Model: Raw Queue
```

</details>

#### 経路 B: CUPS の USB バックエンドを直接叩く ★次の候補

キューを作らず、Apple 署名済みのバックエンドバイナリをそのまま実行する方法。
引数は `job-id user title copies options [file]`。

```bash
# まず疎通確認（引数なしでデバイス一覧）
sudo /usr/libexec/cups/backend/usb

# 送信
sudo env DEVICE_URI='usb://RICOH/SP%206410%20JPN?serial=XXXX-XXXXXX' \
     /usr/libexec/cups/backend/usb 1 "$USER" smoke 1 '' ~/Downloads/smoke-test.rpdl
```

`sudo VAR=x cmd` ではなく `sudo env VAR=x cmd` の形にしているのは、
環境変数の受け渡しを確実にするため。
標準エラーに `DEBUG:` / `INFO:` 付きのログが出ます。

（この手動起動が現行 macOS でも通るかは **未検証**。弾かれたら経路 C へ）

#### 経路 C: libusb で直接書く ★最後の砦

同梱の `usbsend.py`。CUPS を完全に迂回して、USB プリンタークラス (bInterfaceClass=7) の
bulk OUT エンドポイントに生バイトを流し込みます。CUPS の usb バックエンドが
やっていることの最小再現なので、原理的にはこれが一番確実です。

```bash
brew install libusb

# Homebrew / システムの python3 は PEP 668 で pip install を弾くので venv を切る
python3 -m venv ~/.venvs/usb
~/.venvs/usb/bin/pip install pyusb

~/.venvs/usb/bin/python usbsend.py --list        # プリンターが見えるか確認
~/.venvs/usb/bin/python usbsend.py smoke-test.rpdl
```

`--list` に `05ca:xxxx RICOH SP 6410 JPN` のような行が出れば、
CUPS を通さずに書き込める状態です。

CUPS のキューがそのプリンターを掴んでいると排他で失敗するので、
経路 A を試した後なら `cupsdisable SP6410RAW` してから。

### Step 3. 判定

| 結果 | 意味 | 次 |
|---|---|---|
| `smoke-test.rpdl` でテキストが 1 枚出る | RPDL 受信・言語切り替えともに成功 | Step 4 へ |
| 無反応 | 言語切り替えが効いていない | ［テスト印刷］→［ヘキサダンプ］で受信バイトを確認 |
| 文字化け | RPCS のまま解釈されている | 優先エミュレーション／検知の設定を再確認 |
| テキストは出るがテストページが白紙・化ける | ラスタコマンド `G3` が非互換 | `test-a4-240.rpdl` を試す。駄目なら撤退 |
| テストページが正しく出る | **成立** | Step 4 へ |

---

## Step 4. 日常運用

### インストール

```bash
mkdir -p ~/bin
cp sp6410 usbsend.py ~/bin/
chmod +x ~/bin/sp6410
# ~/bin が PATH に無ければ .zshrc に export PATH="$HOME/bin:$PATH"
```

### 基本

```bash
sp6410 資料.pdf                    # A4 600dpi 片面
sp6410 資料.pdf a3                 # A3
sp6410 資料.pdf a4 600 duplex      # 両面（長辺とじ）
sp6410 --convert-only 資料.pdf     # 変換だけ
```

送信先 URI は `lpinfo -v` から自動で拾うので、通常は何も設定不要です。

| 環境変数 | 既定 | 用途 |
|---|---|---|
| `SP6410_SEND` | `backend` | `backend` / `usb` / `queue` |
| `SP6410_URI` | 自動検出 | バックエンドに渡す device URI |
| `SP6410_GS` | `gs` | 自前ビルドの gs を使う場合 |
| `SP6410_PYTHON` | `~/.venvs/usb/bin/python` | `usbsend.py` を動かす python |

### sudo のパスワードを毎回聞かれないようにする

経路 B は root 権限が要ります。このバックエンドだけ NOPASSWD にするなら:

```bash
sudo visudo -f /etc/sudoers.d/sp6410
```

```
<ユーザー名> ALL=(root) NOPASSWD: /usr/libexec/cups/backend/usb
```

> ⚠️ このバックエンドは `DEVICE_URI` で指定した任意の USB プリンターに
> 任意のバイト列を流せます。NOPASSWD にするということは、
> そのユーザーで動く任意のプロセスが同じことをできるということ。
> 気になるなら経路 C（`usbsend.py`、sudo 不要）に寄せてください。

### N-up について

`rpdl` デバイス側の N-up はコマンドエラーになる報告があるので、
面付けは Ghostscript で済ませてから流すのが安全です:

```bash
# pdfjam を使う場合（BasicTeX 同梱）
pdfjam --nup 2x1 --landscape 資料.pdf --outfile 2up.pdf
sp6410 2up.pdf a4

# あるいは mutool
mutool poster -x 1 -y 1 資料.pdf 2up.pdf   # ※ mutool は分割寄り。素直に pdfjam 推奨
```

面付け済みの PDF を `sp6410` に渡せば、あとは 1 ページ 1 枚として流れるだけです。

### 印刷ダイアログへの組み込みについて

**「PDF Services」（`~/Library/PDF Services/` にスクリプトを置いて印刷ダイアログの
PDF メニューから呼ぶ）は使えません。** Big Sur 以降 `printtool` が強くサンドボックス化され、
シェルスクリプトも Python も署名済みバイナリも Automator プラグインも
軒並み実行が拒否されます。Full Disk Access を与えても効きません。Monterey で一瞬直り、
また壊れたまま。Apple から代替の案内も出ていません。

現実的な組み込みは **Finder の右クリック（クイックアクション）** です:

1. Automator →「クイックアクション」
2. ワークフローが受け取る項目: **PDF ファイル**、検索対象: **Finder**
3.「シェルスクリプトを実行」を追加、入力の引き渡し方法を **引数として**
4. 中身:
   ```bash
   for f in "$@"; do /Users/<ユーザー名>/bin/sp6410 "$f"; done
   ```
5. 「SP 6410 で印刷」として保存

これで PDF を右クリック → 印刷、まで持っていけます。
アプリの印刷ダイアログから一発、とはいきませんが、
一旦 PDF にする手間だけで済みます。

### 【未検証】印刷ダイアログ直結の可能性

自前の PPD に `*cupsFilter: "application/pdf 0 /usr/local/bin/rpdl-filter"` と
**絶対パス**でフィルターを指定すれば、SIP で保護された
`/usr/libexec/cups/filter/` に書き込まずに通常のプリンターキューを作れる、
という理屈はあります。ただし macOS は cupsd のフィルター実行にもサンドボックスを
かけているため、標準ディレクトリ外の実行が拒否される可能性があります。
**未検証・推測です。** Step 3 が通ってから、余力があれば試す位置づけ。

---

## 制約（再掲）

- 解像度は 600dpi 上限（エンジンは 1200dpi）。文字物なら実用上問題なし。
- **両面**: `gs -dDuplex=true` は **rpdl デバイスに完全に無視されます**
  （出力が 1 バイトも変わらないことを実測で確認。2010 年の報告と一致）。
  そこで `sp6410` スクリプト側で、最初のラスタコマンドの直前に
  `ESC DC2 "61,"` ＋ `ESC DC2 "YA01,2 "`（短辺とじは `YA01,1`）を注入しています。
  コマンド列はドライバーのソースから起こしたもので、**実機での効き目は未検証**です。
  `./sp6410 資料.pdf a4 600 duplex` / `duplex-short` で試せます。
- N-up は同報告でコマンドエラー。面付けは Ghostscript 側で済ませてから流すのが安全。
- トレイ指定・ステープル等は `rpdl` デバイスの管轄外。プリンター側設定に従う。
- リコーのサポート範囲外。

## 残タスク

- [ ] 両面（`duplex` / `duplex-short`）が実機で効くか確認
- [ ] `usbsend.py`（経路 C）が sudo なしで動くか確認 → 動けば常用をこちらに寄せる
- [ ] Automator のクイックアクション作成
- [ ] **動いている `gs` バイナリの退避**（次のリリースで `rpdl` が削除される予定のため）

```bash
mkdir -p ~/opt/gs-rpdl-backup
cp "$(readlink -f "$(which gs)")" ~/opt/gs-rpdl-backup/gs
gs --version > ~/opt/gs-rpdl-backup/VERSION
```

## もし将来壊れたら

`brew upgrade` で `rpdl` が消えた場合は、この文書の「自前ビルド」節の
`--with-drivers=ALL,rpdl,npdl,escpage,lips4v` でビルドし直すか、
退避しておいたバイナリに戻してください。

それも駄目になったときの代替は **PCL カード タイプ6400**（定価 ¥20,000、中古はもっと安い）
＋ macOS 側は Gutenprint の汎用 PCL PPD。
