# pdftrim

PDF の余白を落として、内容にぴったり合ったページサイズにするコマンドです。
`pdfcrop` と違い、**塗られた白い背景矩形を内容とみなしません**。

```
$ pdftrim paper.pdf
/Users/you/paper-crop.pdf
```

同じことをアプリの画面からしたいときは、PDF を [clip2pdf](README.md) のウィンドウに
ドロップしてください。Keynote の `.key` から図を切り出すなら [key2pdf](key2pdf.md) です。

## 必要なもの

- Node.js 18 以上（`node:util` の `parseArgs` を使います）
- Ghostscript（`gs`）— 切り抜き範囲の検出に使います。MacTeX に同梱、または `brew install ghostscript`

Ruby 版（`ruby/pdftrim`）なら Node.js の代わりに Ruby 2.6 以上と pdfTeX で動きます。
[ruby/README.md](ruby/README.md) を参照してください。

## 導入

```sh
cd clip2pdf && npm install                      # 依存は pdf-lib だけ
ln -s "$PWD/pdftrim" /usr/local/bin/pdftrim   # お好みで PATH へ
```

## 使い方

```
pdftrim [オプション] <file.pdf>
```

| オプション | 説明 |
| --- | --- |
| `-o, --output PATH` | 出力先。`--split` なしはファイル、ありはディレクトリ（既定: `<名前>-crop.pdf`） |
| `--pages SPEC` | 対象ページ。例 `1,3-5`（既定: 全部） |
| `--split` | ページごとに別ファイルへ書き出す |
| `--uniform` | 全ページを共通の矩形（各ページの和）で切り抜き、ページサイズを揃える |
| `--margin PT` | 切り抜きに残す余白 pt（既定: 0） |
| `--dpi N` | 余白判定のラスタ解像度（既定: 150） |
| `--bg auto\|#RRGGBB` | 背景色（既定: `auto` = 四隅から推定） |
| `--tolerance N` | 背景とみなす色差 0–255（既定: 8） |
| `--noise N` | 差分画素が N 個以下の行・列は無視する（既定: 0。スキャンのゴミ対策） |
| `--force` | 既存ファイルを上書きする |
| `-v` / `-q` | 詳細表示 / 進捗を出さない |

```sh
pdftrim paper.pdf                  # → paper-crop.pdf
pdftrim --margin 5 slides.pdf      # 周囲に 5pt 残す
pdftrim --uniform scan.pdf         # 全ページ同じサイズに揃える
pdftrim --split figures.pdf        # → figures-01.pdf, figures-02.pdf …
pdftrim --noise 3 --tolerance 20 scan.pdf   # スキャンの地色とゴミを無視する
```

既定ではページごとに個別の矩形で切り抜いて1本の PDF にまとめます。ページサイズを
揃えたいときは `--uniform` を使ってください。

## 仕組み

1. Ghostscript で1ページずつラスタ化し、**背景色と異なる画素**の範囲を求める
2. [pdf-lib](https://pdf-lib.js.org/) でページの `MediaBox` / `CropBox` をその範囲に付け替える

ラスタ化は Ghostscript に PPM（生の RGB）で吐かせて自前で読むので、画像ライブラリは要りません。
ページの中身は再エンコードしないので**ベクタのまま**です。

`pdfcrop` や `gs -sDEVICE=bbox` を使わないのは、これらが「塗られたかどうか」でしか
判定せず、白い背景矩形を内容とみなしてしまって切り詰められないためです。

## 注意

- **背景が塗り・画像・グラデーションのページは切り抜けません。** 切り抜けなかった場合は
  警告が出るので、`--bg "#RRGGBB"` で背景色を明示するか、`--tolerance` を上げてください。
- スキャン画像など地色にムラがあるものは `--tolerance` を上げ、ゴミは `--noise` で無視できます。
- 切り抜きはページ矩形の付け替えなので、矩形の外の内容はファイル内に残ります
  （表示・印刷はされません）。完全に捨てたい場合は出力を `gs` で再蒸留してください。
- 入力と同じファイルには書き出せません（`-o` で別名を指定してください）。

## テスト

[README.md の「テスト」](README.md#テスト) を参照してください。
