#!/bin/sh
# pdf2rpdl.sh — PDF/PS を Ricoh RPDL に変換する
#
#   ./pdf2rpdl.sh input.pdf out.rpdl [a4|a3] [600|400|240]
#
# 出力はプリンターに「そのまま」流すバイナリ（raw）。
# 例: lp -d SP6410RAW -o raw out.rpdl        (macOS/Linux, raw キュー経由)
#     cat out.rpdl > /dev/usb/lp0             (Linux, USB 直結)

set -eu

IN=${1:?input file}
OUT=${2:?output file}
PAPER=${3:-a4}
DPI=${4:-600}

# -dFIXEDMEDIA が無いと PDF 側の MediaBox が -sPAPERSIZE に勝つ
gs -q -dBATCH -dNOPAUSE -dSAFER \
   -dFIXEDMEDIA -dFitPage \
   -sDEVICE=rpdl \
   -r"$DPI" \
   -sPAPERSIZE="$PAPER" \
   -sOutputFile="$OUT" \
   "$IN"

echo "wrote $OUT ($(wc -c < "$OUT") bytes, ${PAPER} ${DPI}dpi)"

# 両面は -dDuplex=true では出ない（rpdl デバイスが無視する）。
# 両面が要るときは sp6410 の duplex / duplex-short を使う。
