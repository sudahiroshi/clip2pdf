# key2pdf / pdftrim — Ruby + AppleScript 版

Node.js 版（リポジトリ直下の `key2pdf` / `pdftrim`）と**同じ使い方・同じ結果**になる
Ruby 実装です。外部 gem を使いません。

| | Node.js 版 | Ruby 版 |
| --- | --- | --- |
| 実行 | `./key2pdf` / `./pdftrim` | `./ruby/key2pdf` / `./ruby/pdftrim` |
| Keynote 操作 | JXA（JavaScript for Automation） | **AppleScript** |
| PDF の書き出し | pdf-lib でページ矩形を付け替え | **pdfTeX** で元ページを取り込み直す |
| 依存 | Node.js 18+ / pdf-lib / Ghostscript | **Ruby 2.6+ / Ghostscript / pdfTeX**（gem 不要） |

どちらも切り抜き範囲の求め方は同じ（Ghostscript でラスタ化 → 背景色と異なる画素の範囲）で、
出力サイズは一致します。テストは両方を同じ項目で検証しています。

## 使い方

Node 版と同じオプションです。詳細は[親 README](../README.md) を見てください。

```sh
./ruby/key2pdf figures.key              # → figures-01.pdf, figures-02.pdf …
./ruby/pdftrim paper.pdf                # → paper-crop.pdf
./ruby/key2pdf --help
```

PATH に入れるなら:

```sh
ln -s ~/tako/key2pdf/ruby/key2pdf /usr/local/bin/key2pdf-rb
ln -s ~/tako/key2pdf/ruby/pdftrim /usr/local/bin/pdftrim-rb
```

## 構成

```
ruby/
  key2pdf                            # Keynote → 図だけの PDF
  pdftrim                            # PDF の余白削除
  lib/crop.rb                        # 共通処理（ラスタ化・bbox 検出・pdfTeX 出力）
  applescript/export_keynote.applescript   # Keynote への書き出し指示
```

## Node 版との実装上の違い

- **PDF の書き出しに pdfTeX を使います。** 元ページを Form XObject として取り込み、
  ページ矩形だけを目的の大きさにします（`pdfcrop` と同じ方式）。中身は再エンコード
  されないので無劣化ですが、出力1本につき `pdftex` を1回動かすぶん Node 版より遅く、
  PDF の構造は「元ページを1枚貼った新しい PDF」になります（しおりやリンクは残りません）。
- **ページ数は pdfTeX に数えさせています**（`\pdflastximagepages`）。Ghostscript を
  `-dNOSAFER` で動かさずに済ませるためです。
- **bbox 検出は正規表現で行を走査します。** Ruby で画素ループを回すと遅いので、
  行頭・行末の背景画素の連なりを正規表現で一気に飛ばしています。`--noise` を
  指定したときだけ画素を1つずつ数える経路に入ります（その分遅くなります）。
- Keynote の書類は AppleScript でパスを照合して特定し、**こちらで開いた場合だけ閉じます**
  （作業中の書類を勝手に閉じないため）。開いたままの未保存の変更も書き出せます。

## テスト

両実装まとめて回ります。

```sh
./tests/run_tests.sh                 # Keynote は起動しない
./tests/run_tests.sh --with-keynote  # Keynote での書き出しも含める
```
