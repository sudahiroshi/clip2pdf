#!/bin/bash
# tako:run: ./tests/run_tests.sh
# key2pdf の切り抜き処理を検証する。
# 既定では Keynote を起動しないよう、既知の寸法の PDF を pdflatex で作って入力に使う。
# --with-keynote を付けると Keynote での書き出し（①段）を含む通し確認も行う。
set -u
WITH_KEYNOTE=0
[ "${1:-}" = "--with-keynote" ] && WITH_KEYNOTE=1

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TMP="$ROOT/tests/tmp"
KEY2PDF="$ROOT/key2pdf"
PDFTRIM="$ROOT/pdftrim"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { FAIL=$((FAIL+1)); printf '  \033[31mNG\033[0m   %s\n' "$1"; }
check() { # check <説明> <条件コマンド...> : 成功を期待する
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ng "$desc"; fi
}
fails() { # fails <説明> <コマンド...> : 失敗を期待する
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ng "$desc"; else ok "$desc"; fi
}

# 出力 PDF の MediaBox 実寸 "幅 高さ" を返す
pagesize() {
  node -e '
const { PDFDocument } = require("pdf-lib");
const fs = require("node:fs");
(async () => {
  const doc = await PDFDocument.load(fs.readFileSync(process.argv[1]));
  const b = doc.getPage(Number(process.argv[2] || 0)).getMediaBox();
  console.log(b.width.toFixed(2) + " " + b.height.toFixed(2));
})();
' "$1" "${2:-0}"
}

# 出力 PDF のページ数を返す
pagecount() {
  node -e '
const { PDFDocument } = require("pdf-lib");
const fs = require("node:fs");
(async () => {
  const doc = await PDFDocument.load(fs.readFileSync(process.argv[1]));
  console.log(doc.getPageCount());
})();
' "$1"
}

# near <実測> <期待> <許容> : 数値が期待値の許容範囲内か
near() {
  awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'
}

size_is() { # size_is <説明> <pdf> <ページ> <期待幅> <期待高> <許容>
  local desc=$1 pdf=$2 pg=$3 ew=$4 eh=$5 tol=$6
  if [ ! -f "$pdf" ]; then ng "${desc}（$pdf がない）"; return; fi
  local s w h; s=$(pagesize "$pdf" "$pg"); w=${s% *}; h=${s#* }
  if near "$w" "$ew" "$tol" && near "$h" "$eh" "$tol"; then
    ok "${desc}（${w}x${h}pt）"
  else
    ng "$desc: ${w}x${h}pt（期待 ${ew}x${eh}pt ±${tol}）"
  fi
}

rm -rf "$TMP"; mkdir -p "$TMP"

# --- フィクスチャ生成: 720x540pt のページに既知寸法の黒矩形を1つずつ置く ---
cat > "$TMP/fixture.tex" <<'TEX'
\documentclass{article}
\usepackage[paperwidth=720bp,paperheight=540bp,margin=100bp]{geometry}
\pagestyle{empty}
\begin{document}\noindent
\rule{240bp}{120bp}
\newpage\noindent
\rule{100bp}{300bp}
\end{document}
TEX
echo "フィクスチャを生成中..."
(cd "$TMP" && pdflatex -interaction=batchmode fixture.tex >/dev/null 2>&1)
if [ ! -f "$TMP/fixture.pdf" ]; then
  echo "pdflatex でフィクスチャを作れませんでした" >&2; exit 1
fi
size_is "フィクスチャ自体は 720x540pt" "$TMP/fixture.pdf" 0 720 540 0.5

echo "基本の切り抜き"
"$KEY2PDF" -q -o "$TMP/out" "$TMP/fixture.pdf"
size_is "1枚目が矩形の実寸まで縮む" "$TMP/out/fixture-01.pdf" 0 240 120 2
size_is "2枚目が矩形の実寸まで縮む" "$TMP/out/fixture-02.pdf" 0 100 300 2
check "ページ数は1枚ずつ" test "$(pagecount "$TMP/out/fixture-01.pdf")" = 1

echo "--margin"
"$KEY2PDF" -q -o "$TMP/m" --margin 5 "$TMP/fixture.pdf"
size_is "余白 5pt で縦横とも 10pt 大きい" "$TMP/m/fixture-01.pdf" 0 250 130 2

echo "--slide / --prefix / --merge / --bg none"
"$KEY2PDF" -q -o "$TMP/s" --slide 2 --prefix fig "$TMP/fixture.pdf"
size_is "--slide 2 は2枚目だけを出す" "$TMP/s/fig-02.pdf" 0 100 300 2
check "--slide 2 で1枚目は作られない" test ! -f "$TMP/s/fig-01.pdf"
"$KEY2PDF" -q -o "$TMP/g" --merge "$TMP/fixture.pdf"
check "--merge は1本にまとまる" test -f "$TMP/g/fixture.pdf"
size_is "--merge 1ページ目" "$TMP/g/fixture.pdf" 0 240 120 2
size_is "--merge 2ページ目" "$TMP/g/fixture.pdf" 1 100 300 2
"$KEY2PDF" -q -o "$TMP/n" --bg none "$TMP/fixture.pdf"
size_is "--bg none は切り抜かない" "$TMP/n/fixture-01.pdf" 0 720 540 0.5

echo "エラー処理"
fails "存在しない入力は失敗する" "$KEY2PDF" -q "$TMP/nope.key"
fails "未対応の拡張子は失敗する" "$KEY2PDF" -q "$TMP/fixture.tex"
fails "範囲外のスライドは失敗する" "$KEY2PDF" -q -o "$TMP/e" --slide 9 "$TMP/fixture.pdf"
fails "--slide の書式不正は失敗する" "$KEY2PDF" -q -o "$TMP/e" --slide "a-b" "$TMP/fixture.pdf"
fails "既存ファイルは上書きしない" "$KEY2PDF" -q -o "$TMP/out" "$TMP/fixture.pdf"
check "--force なら上書きする" "$KEY2PDF" -q --force -o "$TMP/out" "$TMP/fixture.pdf"

echo "pdftrim: PDF の余白削除"
"$PDFTRIM" -q -o "$TMP/t/paper-crop.pdf" "$TMP/fixture.pdf"
size_is "既定は全ページを個別に切り抜いて1本にまとめる(1p)" "$TMP/t/paper-crop.pdf" 0 240 120 2
size_is "同(2p)" "$TMP/t/paper-crop.pdf" 1 100 300 2
check "既定の出力名は <名前>-crop.pdf" bash -c '"$0" -q "$1" && test -f "$2"' "$PDFTRIM" "$TMP/fixture.pdf" "$TMP/fixture-crop.pdf"
"$PDFTRIM" -q --uniform -o "$TMP/t/uni.pdf" "$TMP/fixture.pdf"
U1=$(pagesize "$TMP/t/uni.pdf" 0); U2=$(pagesize "$TMP/t/uni.pdf" 1)
check "--uniform は全ページ同じサイズ" test "$U1" = "$U2"
size_is "--uniform は各ページの和になる" "$TMP/t/uni.pdf" 0 240 300 2
"$PDFTRIM" -q --split -o "$TMP/t/sp" "$TMP/fixture.pdf"
size_is "--split は1ページ1ファイル(1枚目)" "$TMP/t/sp/fixture-01.pdf" 0 240 120 2
size_is "--split は1ページ1ファイル(2枚目)" "$TMP/t/sp/fixture-02.pdf" 0 100 300 2
"$PDFTRIM" -q --pages 2 -o "$TMP/t/p2.pdf" "$TMP/fixture.pdf"
size_is "--pages 2 は2ページ目だけ" "$TMP/t/p2.pdf" 0 100 300 2
check "--pages 2 の出力は1ページ" test "$(pagecount "$TMP/t/p2.pdf")" = 1
"$PDFTRIM" -q --margin 5 -o "$TMP/t/m.pdf" "$TMP/fixture.pdf"
size_is "--margin 5 で縦横とも 10pt 大きい" "$TMP/t/m.pdf" 0 250 130 2

echo "pdftrim: ゴミ取り (--noise)"
cat > "$TMP/speck.tex" <<'TEX'
\documentclass{article}
\usepackage[paperwidth=720bp,paperheight=540bp,margin=100bp]{geometry}
\pagestyle{empty}
\begin{document}\noindent
\rule{240bp}{120bp}\hspace{200bp}\rule{0.4bp}{0.4bp}
\end{document}
TEX
(cd "$TMP" && pdflatex -interaction=batchmode speck.tex >/dev/null 2>&1)
"$PDFTRIM" -q -o "$TMP/t/speck-raw.pdf" "$TMP/speck.pdf"
SP=$(pagesize "$TMP/t/speck-raw.pdf"); SPW=${SP% *}
if near "$SPW" 240 5; then ng "ゴミが既定で無視されてしまっている（${SPW}pt）"; else ok "既定ではゴミも内容として拾う（${SPW}pt）"; fi
"$PDFTRIM" -q --noise 3 -o "$TMP/t/speck-clean.pdf" "$TMP/speck.pdf"
size_is "--noise 3 でゴミを無視して図の実寸になる" "$TMP/t/speck-clean.pdf" 0 240 120 3

echo "pdftrim: エラー処理"
fails "PDF 以外は失敗する" "$PDFTRIM" -q "$TMP/fixture.tex"
fails "入力と同じファイルへの出力は失敗する" "$PDFTRIM" -q -o "$TMP/fixture.pdf" "$TMP/fixture.pdf"
fails "既存ファイルは上書きしない" "$PDFTRIM" -q -o "$TMP/t/m.pdf" "$TMP/fixture.pdf"
check "--force なら上書きする" "$PDFTRIM" -q --force -o "$TMP/t/m.pdf" "$TMP/fixture.pdf"

echo "TeX に貼れるか"
cat > "$TMP/use.tex" <<'TEX'
\documentclass{article}
\usepackage{graphicx}
\begin{document}
\includegraphics[width=0.8\linewidth]{out/fixture-01.pdf}
\includegraphics[width=3cm]{out/fixture-02.pdf}
\end{document}
TEX
check "pdflatex で \\includegraphics が通る" bash -c "cd '$TMP' && pdflatex -interaction=batchmode use.tex"

if [ "$WITH_KEYNOTE" = 1 ]; then
  echo "Keynote からの通し確認"
  SAMPLE="$TMP/sample.key"
  if osascript tests/make_sample_key.applescript "$SAMPLE" >/dev/null 2>&1 && [ -e "$SAMPLE" ]; then
    ok "サンプル .key を生成した"
    if "$KEY2PDF" -q -o "$TMP/key" "$SAMPLE"; then
      ok ".key から PDF を書き出して切り抜いた"
      for n in 01 02; do
        f="$TMP/key/sample-$n.pdf"
        if [ -f "$f" ]; then
          s=$(pagesize "$f"); w=${s% *}; h=${s#* }
          # 1920x1080pt のスライドから、置いたテキストの大きさまで縮んでいるか
          if near "$w" 0 400 && near "$h" 0 200 && ! near "$w" 0 1; then
            ok "スライド $n が内容の実寸まで縮んだ（${w}x${h}pt）"
          else
            ng "スライド $n の切り抜きが怪しい: ${w}x${h}pt（元は 1920x1080pt）"
          fi
        else
          ng "スライド $n の出力がない"
        fi
      done
    else
      ng ".key の変換に失敗した"
    fi
  else
    ng "サンプル .key を生成できなかった（Keynote の自動化許可を確認してください）"
  fi
fi

echo
printf '成功 %d / 失敗 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
