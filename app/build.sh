#!/bin/bash
# tako:run: ./app/build.sh
# clip2pdf.app をビルドする。出力は app/build/clip2pdf.app。
#
# 環境変数 CODESIGN_IDENTITY に Developer ID を入れると、その証明書で
# 署名する（Hardened Runtime ＋ entitlements 付き。公証に出せる形）。
# 省略した場合はアドホック署名。配布まで行うなら app/sign.sh を使う。
set -eu
cd "$(dirname "$0")"
OUT=build
APP="$OUT/clip2pdf.app"
IDENTITY="${CODESIGN_IDENTITY:-}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/clip2pdf" main.swift
cp Info.plist "$APP/Contents/Info.plist"

if [ -n "$IDENTITY" ]; then
  # AppleEvent を送るので entitlements が要る。付け忘れると署名は通るのに
  # Keynote を操作できないアプリになる
  codesign --force --timestamp --options runtime \
    --entitlements clip2pdf.entitlements \
    --sign "$IDENTITY" "$APP"
  echo "署名: $IDENTITY" >&2
else
  # 署名しないと起動時に弾かれることがあるのでアドホック署名する
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "警告: 署名に失敗しました（起動はできます）" >&2
fi

echo "$PWD/$APP"
echo "起動: open $APP"
