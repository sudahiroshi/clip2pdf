#!/bin/bash
# tako:run: ./app/sign.sh
# clip2pdf.app を Developer ID で署名し、公証して、配布用の zip を作る。
#
#   ./app/sign.sh                # 署名 → 公証 → staple → zip
#   SKIP_NOTARIZE=1 ./app/sign.sh   # 署名だけ（手元で使う分にはこれで十分）
#
# 環境変数
#   CODESIGN_IDENTITY  使う証明書（省略時はキーチェーンの Developer ID を自動で探す）
#   NOTARY_PROFILE     notarytool のプロファイル名（既定: clip2pdf）
#
# 公証の認証情報は先に一度だけ保存しておく:
#   xcrun notarytool store-credentials clip2pdf \
#     --apple-id "<Apple ID>" --team-id "<チームID>" --password "<App 用パスワード>"
set -eu
cd "$(dirname "$0")/.."
APP=app/build/clip2pdf.app
ZIP=app/build/clip2pdf.app.zip
PROFILE="${NOTARY_PROFILE:-clip2pdf}"

# 証明書を決める
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  echo "Developer ID Application の証明書が見つかりません。" >&2
  echo "Xcode > Settings > Accounts から作成するか、CODESIGN_IDENTITY で指定してください。" >&2
  exit 1
fi

echo "== ビルドして署名します（${IDENTITY}）"
CODESIGN_IDENTITY="$IDENTITY" ./app/build.sh >/dev/null

echo "== 署名を確認します"
codesign --verify --strict --verbose=2 "$APP"
# entitlements が入っていないと Keynote を操作できないので必ず見る
if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null \
     | grep -q "com.apple.security.automation.apple-events"; then
  echo "entitlements に apple-events がありません。署名をやり直してください。" >&2
  exit 1
fi
echo "   entitlements: apple-events あり"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "== 公証は省略しました（SKIP_NOTARIZE=1）"
  echo "$APP"
  exit 0
fi

echo "== 公証に出します（数分かかります）"
rm -f "$ZIP"
# .app は zip ではなく ditto で固める（属性やリンクを壊さないため）
ditto -c -k --keepParent "$APP" "$ZIP"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
  echo "" >&2
  echo "公証に失敗しました。認証情報が未登録なら次を一度だけ実行してください:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "    --apple-id \"<Apple ID>\" --team-id \"<チームID>\" --password \"<App 用パスワード>\"" >&2
  echo "理由を見る:  xcrun notarytool log <提出ID> --keychain-profile $PROFILE" >&2
  exit 1
fi

echo "== 結果をアプリに貼り付けて、zip を作り直します"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== 最終確認"
spctl --assess --type execute -vvv "$APP" 2>&1 | sed 's/^/   /'
xcrun stapler validate "$APP" | sed 's/^/   /'

echo ""
echo "配布用: $PWD/$ZIP"
