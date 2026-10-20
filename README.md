# key2pdf / pdftrim

余白のない図の PDF を作るコマンドが2つ入っています。

| コマンド | 用途 |
| --- | --- |
| `key2pdf` | Keynote の `.key` から、スライドごとに**図の部分だけ**を切り出した PDF を作る |
| `pdftrim` | できあいの **PDF の余白を落として**、内容にぴったりのページサイズにする |

切り抜きの中身は `lib/crop.js` で共通です。
同じものの **Ruby + AppleScript 版**が `ruby/` にあります（[ruby/README.md](ruby/README.md)）。
使い方・出力は Node 版と同じで、gem を使いません。

## 必要なもの

- macOS + Keynote（`key2pdf` が `.key` を書き出すのに使います。`pdftrim` には不要）
- Node.js 18 以上（`node:util` の `parseArgs` を使います。Ruby 版なら Ruby 2.6 以上と pdfTeX）
- Ghostscript（`gs`）— 切り抜き範囲の検出に使います。MacTeX に同梱、または `brew install ghostscript`

## 導入

```sh
git clone <this repo> ~/tako/key2pdf
cd ~/tako/key2pdf && npm install                      # 依存は pdf-lib だけ
ln -s ~/tako/key2pdf/key2pdf /usr/local/bin/key2pdf   # お好みで PATH へ
ln -s ~/tako/key2pdf/pdftrim /usr/local/bin/pdftrim
```

## key2pdf

Keynote のスライドを、**図の部分だけを切り出した PDF** に変換します。

Keynote の書き出しは「スライド1枚 = 1ページ」なので、図の周りにスライドの余白が
そのまま残ります。そのまま TeX に貼ると巨大な空白付きの図になってしまうので、
本ツールは余白を落とし、図にぴったり合ったサイズの PDF を作ります。
中身は再エンコードしないので**ベクタのまま**です。

```
$ key2pdf figures.key
/Users/you/figures-01.pdf
/Users/you/figures-02.pdf
```

```latex
\includegraphics[width=0.8\linewidth]{figures-01.pdf}
```

### 使い方

```
key2pdf [オプション] <file.key | file.pdf>
```

| オプション | 説明 |
| --- | --- |
| `-o, --output DIR` | 出力先ディレクトリ（既定: 入力と同じ場所） |
| `--prefix NAME` | 出力名の接頭辞（既定: 入力ファイル名） |
| `--slide SPEC` | 対象スライドを限定。例 `1,3-5`（既定: 全部） |
| `--margin PT` | 切り抜きに残す余白 pt（既定: 0） |
| `--dpi N` | 切り抜き範囲を調べるときのラスタ解像度（既定: 150） |
| `--bg auto\|#RRGGBB\|none` | 背景色。`auto` は四隅から推定、`none` で切り抜きなし |
| `--tolerance N` | 背景とみなす色差 0–255（既定: 8） |
| `--noise N` | 差分画素が N 個以下の行・列は無視する（既定: 0） |
| `--merge` | 複数ページの PDF 1本にまとめる |
| `--force` | 既存ファイルを上書きする |
| `--keep-uncropped` | 切り抜き前の PDF も残す（デバッグ用） |
| `-v` / `-q` | 詳細表示 / 進捗を出さない |

出力名は `<prefix>-01.pdf`, `-02.pdf`, … です（書類が1枚だけのときは連番なし）。

```sh
key2pdf figures.key                        # 全スライドを1枚ずつ
key2pdf --slide 3 --margin 2 figures.key   # 3枚目だけ、周囲に 2pt 残す
key2pdf -o ~/paper/fig --prefix energy figures.key
key2pdf slides.pdf                         # 書き出し済み PDF の切り抜きだけ
```

## pdftrim

PDF の余白を落とします。`pdfcrop` と違い、**塗られた白い背景矩形を内容とみなしません**。

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

1. （key2pdf のみ）AppleScript（JXA）で Keynote に PDF を書き出させる
2. Ghostscript で1ページずつラスタ化し、**背景色と異なる画素**の範囲を求める
3. [pdf-lib](https://pdf-lib.js.org/) でページの `MediaBox` / `CropBox` をその範囲に付け替える

ラスタ化は Ghostscript に PPM（生の RGB）で吐かせて自前で読むので、画像ライブラリは要りません。

`pdfcrop` や `gs -sDEVICE=bbox` を使わないのは、これらが「塗られたかどうか」でしか
判定せず、Keynote が必ず描くスライド背景の白い矩形を内容とみなしてしまい、
まったく切り詰められないためです。

## 注意

以下のうち Keynote に関する項目は `key2pdf` のみに当てはまります。

- **Keynote の GUI が起動します。** ヘッドレス実行や ssh 越しの実行はできません。
  初回は「システム設定 > プライバシーとセキュリティ > オートメーション」で、
  ターミナルから Keynote を操作する許可を求められます。
- **1スライド1図の運用が前提です。** スライド上の可視要素すべてが切り抜き対象なので、
  タイトル文字などを含めたくないならスライドに置かないでください。
- **テーマ背景が塗り・画像・グラデーションだと切り抜けません。** 白無地のテーマを推奨します。
  切り抜けなかった場合は警告が出るので、`--bg "#RRGGBB"` で背景色を明示するか、
  `--tolerance` を上げてください。
- Keynote で使ったフォントはサブセットが PDF に埋め込まれます。TeX 本文のフォントには揃いません。
- パスワード保護された `.key` は書き出せません。
- Keynote で「スライドをスキップ」にしたスライドは書き出されません。その分だけ
  `--slide` の番号と Keynote 上のスライド番号がずれます（枚数が食い違うと警告を出します）。
- 切り抜きはページ矩形の付け替えなので、矩形の外の内容はファイル内に残ります
  （表示・印刷はされません）。完全に捨てたい場合は出力を `gs` で再蒸留してください。

## テスト

```sh
npm test          # = ./tests/run_tests.sh
```

既知の寸法の PDF を `pdflatex` で作り、**Node 版と Ruby 版の両方**について
切り抜き結果の実寸・`--margin`・`--slide` / `--pages`・`--merge` / `--split` / `--uniform`・
`--noise`・エラー処理・`\includegraphics` の通りを検証します（Keynote は起動しません）。

Keynote からの書き出しを含む通し確認も行うなら、`--with-keynote` を付けます
（Keynote が起動し、サンプル書類を作って変換まで通します）。

```sh
./tests/run_tests.sh --with-keynote
```
