# 配布の手順

clip2pdf の配り方は 3 通りあります。下に行くほど受け取る人が楽になり、
用意する側の手間（と費用）が増えます。

| 方法 | 受け取る人の手間 | 用意する側 |
| --- | --- | --- |
| ソースからビルドしてもらう | `git clone` して `./app/build.sh` | 何も要らない |
| Releases にビルド済み `.app` を置く | ダウンロード＋**警告を手動で解除** | タグを push するだけ |
| Developer ID で署名・公証して置く | ダウンロードして開くだけ | Apple Developer Program（年 $99） |

## 1. ソース配布

README の手順そのままです。**自分でビルドした `.app` には quarantine 属性が付かない**ので、
Gatekeeper に止められません。未署名のまま配るなら一番トラブルが少ない方法です。

## 2. Releases にビルド済みアプリを置く

`.github/workflows/release.yml` が入っています。タグを push すると macOS ランナーで
ビルドし、`clip2pdf.app.zip` を Releases に添付します。

```sh
git tag v1.0.0
git push origin v1.0.0
```

手元で作って手で添付する場合は次のとおりです。`.app` は `zip` ではなく `ditto` で
固めてください（属性やシンボリックリンクが壊れないようにするため）。

```sh
./app/build.sh
ditto -c -k --keepParent app/build/clip2pdf.app clip2pdf.app.zip
gh release create v1.0.0 clip2pdf.app.zip --title "clip2pdf v1.0.0" --notes-file -
```

**受け取った人は次のどちらかが必要です**（未署名のため）。

- 一度開こうとしてから、システム設定 > プライバシーとセキュリティ > 「このまま開く」
- または `xattr -dr com.apple.quarantine /Applications/clip2pdf.app`

macOS 15 以降は「右クリック → 開く」では回避できなくなっています。

また、**アドホック署名はビルドのたびに変わる**ため、アプリを更新すると
オートメーション／アクセシビリティの許可を取り直すことになります。

## 3. Developer ID で署名して公証する

Apple Developer Program に加入し、「Developer ID Application」証明書を
キーチェーンに入れてから行います。公証まで通せば、受け取った人はダウンロードして
そのまま開けます。**署名が安定するので、アプリを更新しても許可が維持されます。**

```sh
# 1. ビルド
./app/build.sh

# 2. 署名（Hardened Runtime ＋ entitlements）
#    AppleEvent を送るアプリなので com.apple.security.automation.apple-events が要る
codesign --force --timestamp --options runtime \
  --entitlements app/clip2pdf.entitlements \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  app/build/clip2pdf.app

# 3. 固めて公証に出す
ditto -c -k --keepParent app/build/clip2pdf.app clip2pdf.app.zip
xcrun notarytool submit clip2pdf.app.zip \
  --apple-id "you@example.com" --team-id "TEAMID" \
  --password "アプリ用パスワード" --wait

# 4. 結果をアプリに貼り付けて、固め直す
xcrun stapler staple app/build/clip2pdf.app
rm clip2pdf.app.zip
ditto -c -k --keepParent app/build/clip2pdf.app clip2pdf.app.zip

# 5. 確認（accepted / Notarized Developer ID と出れば成功）
spctl -a -vvv -t install app/build/clip2pdf.app
```

`--password` には Apple ID のパスワードではなく
[アプリ用パスワード](https://support.apple.com/ja-jp/102654)を使います。
`xcrun notarytool store-credentials` で一度保存しておくと、以後は
`--keychain-profile <名前>` で済みます。

### GitHub Actions で署名・公証まで行う場合

リポジトリの Secrets に次を入れ、`release.yml` のビルド後に署名の手順を足します。

| Secret | 中身 |
| --- | --- |
| `CERT_P12_BASE64` | 書き出した証明書（.p12）を `base64` にしたもの |
| `CERT_PASSWORD` | .p12 のパスワード |
| `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` | 公証用 |

ランナー上では一時キーチェーンを作って証明書を取り込みます。

```sh
security create-keychain -p "$RANDOM_PW" build.keychain
security default-keychain -s build.keychain
security unlock-keychain -p "$RANDOM_PW" build.keychain
echo "$CERT_P12_BASE64" | base64 -d > cert.p12
security import cert.p12 -k build.keychain -P "$CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$RANDOM_PW" build.keychain
```

**証明書と鍵はリポジトリに置かないでください。** 必ず Secrets 経由で渡します。

## 公開前の確認

- `LICENSE` があるか（MIT）
- README の導入手順が clone からになっているか
- `git status` が綺麗か（`app/build/` と `node_modules/` は `.gitignore` 済み）
- 個人のパスや秘密が混ざっていないか：`git grep -n "/Users/"`
