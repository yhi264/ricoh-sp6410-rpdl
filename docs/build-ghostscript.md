# rpdl 入りの Ghostscript を用意する

## 現状（2026 年 10 月）

- **10.07.1 まで：** `rpdl` は既定のビルドに入っている。Homebrew の gs も 10.07.1 までは rpdl を含んでいた
- **10.08.0（2026-09-08）：** `rpdl` を含む contrib のデバイス 140 種が既定のビルドから外れた（[コミット 272e19ee6f](https://github.com/ArtifexSoftware/ghostpdl/commit/272e19ee6f)）。Homebrew もこの版に上がっていて、`brew install ghostscript` では rpdl が入らない
- **10.09.0（未リリース）：** テスターが現れなければ、ソースごと削除する予定。開発元は、実機でテストできる人が名乗り出れば既定のビルドに戻すとしている（[Bug 709798](https://bugs.ghostscript.com/show_bug.cgi?id=709798) の回答）

## 手元の gs を確かめる

```bash
gs --version
gs -h | tr ' ' '\n' | grep -x rpdl     # "rpdl" と出れば使える
```

10.07.1 の Homebrew の gs が入っていて rpdl が使えるなら、`brew upgrade` で消えないように固定しておくと安全です。

```bash
brew pin ghostscript
```

## 自分でビルドする

10.07.1 か 10.08.0 のソースを使います。`--with-drivers` に `rpdl` を名前で並べると、10.08.0 でも組み込まれます（configure は未知の語をそのままデバイス名として扱います）。

```bash
brew install pkgconf freetype libpng jpeg-turbo libtiff little-cms2 \
             openjpeg jbig2dec fontconfig libidn libarchive leptonica

curl -LO https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10080/ghostpdl-10.08.0.tar.xz
tar xf ghostpdl-10.08.0.tar.xz && cd ghostpdl-10.08.0

./configure --prefix="$HOME/opt/gs-rpdl" \
            --with-drivers=ALL,rpdl \
            --disable-cups --disable-gtk --without-x \
            --without-versioned-path
make -j"$(sysctl -n hw.ncpu)" && make install

"$HOME/opt/gs-rpdl/bin/gs" -h | tr ' ' '\n' | grep -x rpdl
```

- `--disable-contrib` は**付けない**。contrib のデバイスがまとめて外れ、rpdl も消える
- `--disable-compile-inits` も付けない。初期化ファイルがバイナリに焼き込まれ、`gs_init.ps` が見つからない問題が起きなくなる
- configure の最後に「The following devices are deprecated: rpdl」という警告が出る。10.08.0 では正常な動作

ビルドした gs をインストーラーに渡します。

```bash
cd ricoh-sp6410-rpdl/gui
sudo SP6410_GS="$HOME/opt/gs-rpdl/bin/gs" ./install-gui-queue.sh
```

## ソースを保管しておく

10.09.0 で rpdl のソースが削除されると、新しい版からは組み込めなくなります。10.07.1 か 10.08.0 の tarball を手元に残しておくと安心です。公式の配布物は [ghostpdl-downloads のリリース](https://github.com/ArtifexSoftware/ghostpdl-downloads/releases)にあり、`SHA512SUMS` で照合できます。

```bash
grep ' ghostpdl-10.08.0.tar.xz' SHA512SUMS | shasum -a 512 -c -
```
