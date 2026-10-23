#!/bin/bash
# install-gui-queue.sh — SP 6410 を macOS の印刷ダイアログに出す
#
#   sudo ./install-gui-queue.sh
#   sudo ./install-gui-queue.sh --no-bundle    # gs を同梱せず既存のものを直接使う
#
# なぜ同梱するのか:
#   macOS の cupsd はフィルターをサンドボックス下で実行し、/opt/homebrew 配下の
#   dylib 読み込みを拒否する。実測されたエラー:
#     dyld: Library not loaded: /opt/homebrew/opt/jbig2dec/lib/libjbig2dec.0.dylib
#           Reason: tried: '...' (blocked by sandbox)
#   gs の exec 自体は通るのに dylib だけ弾かれる。よって gs・依存 dylib・
#   Resource 一式を /Library/Printers/ 配下（ベンダードライバーが使う場所）に
#   引っ越す。Homebrew の更新から独立するという副次効果もある。
#
# アンインストール:
#   sudo lpadmin -x SP6410
#   sudo rm -rf /Library/Printers/RICOH-RPDL

set -euo pipefail

DEST="/Library/Printers/RICOH-RPDL"
QUEUE="${SP6410_QUEUE_NAME:-SP6410}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE=1

[ "${1:-}" = "--no-bundle" ] && BUNDLE=0

if [ "$(id -u)" -ne 0 ]; then
  echo "sudo で実行してください: sudo $0" >&2
  exit 1
fi

# --- 同梱物のバージョン整合チェック ------------------------------------------
# インストーラーだけ新しくしてフィルターが古いままだと、gs は同梱先に引っ越すのに
# フィルターが -I を渡さず "Can't find initialization file gs_init.ps" になる。
for f in pdftorpdl rpdl-sp6410.ppd; do
  [ -f "$SRC_DIR/$f" ] || { echo "error: $SRC_DIR/$f がありません" >&2; exit 1; }
done
if ! grep -q '@GSSHARE@' "$SRC_DIR/pdftorpdl"; then
  {
    echo "error: $SRC_DIR/pdftorpdl が古い版です（@GSSHARE@ を含んでいません）。"
    echo "       このインストーラーと同じ版の pdftorpdl に差し替えてください。"
    echo "       古いままだと gs_init.ps が見つからず変換に失敗します。"
  } >&2
  exit 1
fi

say() { printf '\n=== %s\n' "$*"; }

# ---------------------------------------------------------------- gs を探す --
say "Ghostscript を探す"

GS="${SP6410_GS:-}"
CANDIDATES=(
  /opt/homebrew/bin/gs
  /usr/local/bin/gs
  /opt/local/bin/gs
  "$(command -v gs 2>/dev/null || true)"
)
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME="$(eval echo "~$SUDO_USER")"
  CANDIDATES+=(
    "$USER_HOME/opt/gs-rpdl/bin/gs"
    "$USER_HOME/bin/gs"
    "$(sudo -u "$SUDO_USER" -i command -v gs 2>/dev/null || true)"
  )
fi

if [ -z "$GS" ]; then
  for c in "${CANDIDATES[@]}"; do
    [ -n "$c" ] && [ -x "$c" ] && { GS="$c"; break; }
  done
fi

if [ -z "$GS" ]; then
  {
    echo "error: gs が見つかりません。探した場所:"
    for c in "${CANDIDATES[@]}"; do [ -n "$c" ] && echo "  - $c"; done
    echo
    echo "未インストールなら:  brew install ghostscript"
    echo "パスを明示する場合:  sudo SP6410_GS=/path/to/gs $0"
  } >&2
  exit 1
fi

GS_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$GS")"

if ! "$GS_REAL" -h 2>&1 | tr ' ' '\n' | grep -x rpdl >/dev/null; then
  {
    echo "error: $GS_REAL に rpdl デバイスがありません。"
    echo "       ($("$GS_REAL" --version 2>/dev/null || echo '版数不明'))"
    echo "       docs/build-ghostscript.md を参照。"
  } >&2
  exit 1
fi
GS_VER="$("$GS_REAL" --version)"
echo "gs: $GS_REAL ($GS_VER)"

# --- Resource ツリーを探す（Resource/Init/gs_init.ps があるディレクトリ）----
# Homebrew は --without-versioned-path でビルドしているのでバージョン無しの
# 場合もあれば、Cellar 側にバージョン付きで入っている場合もある。両方見る。
GS_PREFIX="$(dirname "$(dirname "$GS_REAL")")"
GSSHARE_SRC=""
for d in \
  "$GS_PREFIX/share/ghostscript" \
  "$GS_PREFIX/share/ghostscript/$GS_VER" \
  "$GS_PREFIX/share/ghostscript"/*; do
  if [ -f "$d/Resource/Init/gs_init.ps" ]; then GSSHARE_SRC="$d"; break; fi
done

if [ -z "$GSSHARE_SRC" ]; then
  echo "warning: gs の Resource ツリーが見つかりません（$GS_PREFIX/share/ghostscript 付近）" >&2
  echo "         同梱を諦めて --no-bundle 相当で続行します。" >&2
  BUNDLE=0
else
  echo "resources: $GSSHARE_SRC"
fi

# ------------------------------------------------------------ 設置ディレクトリ --
say "$DEST に設置"
mkdir -p "$DEST/filter"

GS_FOR_FILTER="$GS_REAL"
GSSHARE_FOR_FILTER="${GSSHARE_SRC:-}"

if [ "$BUNDLE" -eq 1 ]; then
  # ---------------------------------------------------------- gs を同梱する --
  DYLIBBUNDLER="$(command -v dylibbundler || true)"
  [ -z "$DYLIBBUNDLER" ] && [ -x /opt/homebrew/bin/dylibbundler ] && DYLIBBUNDLER=/opt/homebrew/bin/dylibbundler
  [ -z "$DYLIBBUNDLER" ] && [ -x /usr/local/bin/dylibbundler ] && DYLIBBUNDLER=/usr/local/bin/dylibbundler

  if [ -z "$DYLIBBUNDLER" ]; then
    {
      echo "error: dylibbundler が必要です:"
      echo "         brew install dylibbundler"
      echo "       同梱せずに試すなら（サンドボックスに弾かれる可能性が高い）:"
      echo "         sudo $0 --no-bundle"
    } >&2
    exit 1
  fi

  say "gs と依存 dylib を同梱"
  rm -rf "$DEST/bin" "$DEST/lib" "$DEST/share"
  mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/share"

  cp "$GS_REAL" "$DEST/bin/gs"
  chmod 755 "$DEST/bin/gs"

  # 依存 dylib を集めて install_name を @executable_path/../lib に書き換える
  "$DYLIBBUNDLER" -od -of -b \
    -x "$DEST/bin/gs" \
    -d "$DEST/lib" \
    -p '@executable_path/../lib' \
    -i /usr/lib -i /System/Library

  cp -R "$GSSHARE_SRC" "$DEST/share/ghostscript"

  # Apple Silicon では Mach-O を書き換えると署名が壊れ、起動が拒否される。
  # ad-hoc 署名を付け直す。これを忘れると "Killed: 9" になる。
  say "ad-hoc 署名を付け直す"
  find "$DEST/lib" -name '*.dylib' -type f -print0 \
    | xargs -0 -n1 codesign --force --sign - 2>/dev/null || true
  codesign --force --sign - "$DEST/bin/gs"

  GS_FOR_FILTER="$DEST/bin/gs"
  GSSHARE_FOR_FILTER="$DEST/share/ghostscript"

  # 同梱した gs が単体で動くか、rpdl が生きているかを確認
  say "同梱した gs を検証"
  if ! "$GS_FOR_FILTER" --version >/dev/null 2>&1; then
    echo "error: 同梱した gs が起動しません。詳細:" >&2
    "$GS_FOR_FILTER" --version || true
    exit 1
  fi
  if ! "$GS_FOR_FILTER" -h 2>&1 | tr ' ' '\n' | grep -x rpdl >/dev/null; then
    echo "error: 同梱した gs に rpdl がありません。" >&2
    exit 1
  fi
  echo "ok: $("$GS_FOR_FILTER" --version) / rpdl あり"
  echo "残っている外部依存（/usr/lib と /System 以外があれば要注意）:"
  otool -L "$DEST/bin/gs" | tail -n +2 | awk '{print "  " $1}' \
    | grep -v -E '^\s+(/usr/lib|/System/Library|@executable_path)' || echo "  （なし）"
fi

# -------------------------------------------------------- フィルターと PPD --
sed -e "s|@GS@|$GS_FOR_FILTER|" \
    -e "s|@GSSHARE@|$GSSHARE_FOR_FILTER|" \
    "$SRC_DIR/pdftorpdl" > "$DEST/filter/pdftorpdl"
cp "$SRC_DIR/rpdl-sp6410.ppd" "$DEST/rpdl-sp6410.ppd"

chown -R root:wheel "$DEST"
chmod 755 "$DEST" "$DEST/filter" "$DEST/filter/pdftorpdl"
[ -d "$DEST/bin" ] && chmod 755 "$DEST/bin" "$DEST/bin/gs"
chmod 644 "$DEST/rpdl-sp6410.ppd"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installed: $DEST"

# ------------------------------------------------------------- キュー作成 --
say "プリンターキューを作成"
URI="${SP6410_URI:-$(lpinfo -v 2>/dev/null | awk '/usb:\/\// {print $2; exit}')}"
[ -n "$URI" ] || { echo "error: USB プリンターが見つかりません（lpinfo -v で確認）" >&2; exit 1; }
echo "uri: $URI"

lpadmin -p "$QUEUE" -E \
  -v "$URI" \
  -P "$DEST/rpdl-sp6410.ppd" \
  -D "RICOH SP 6410 (RPDL)" \
  -L "USB" \
  -o printer-is-shared=false

lpstat -p "$QUEUE" || true

cat <<EOF

--- 完了 ---
「システム設定 → プリンタとスキャナ」に "$QUEUE" が出ているはずです。

テスト:
    lp -d $QUEUE ~/Downloads/test.pdf

ログ:
    sudo cupsctl --debug-logging
    lp -d $QUEUE ~/Downloads/test.pdf
    grep -aE 'pdftorpdl|gs:' /private/var/log/cups/error_log | tail -40
    sudo cupsctl --no-debug-logging

アンインストール:
    sudo lpadmin -x $QUEUE && sudo rm -rf $DEST
EOF
