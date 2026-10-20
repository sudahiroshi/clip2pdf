#!/bin/bash
# tako:run: ./app/build.sh
# clip2pdf.app をビルドする。出力は app/build/clip2pdf.app。
set -eu
cd "$(dirname "$0")"
OUT=build
APP="$OUT/clip2pdf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/clip2pdf" main.swift
cp Info.plist "$APP/Contents/Info.plist"
# 署名しないと起動時に弾かれることがあるのでアドホック署名する
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "警告: 署名に失敗しました（起動はできます）" >&2

echo "$PWD/$APP"
echo "起動: open $APP"
