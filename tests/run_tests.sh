#!/bin/bash
# tako:run: ./tests/run_tests.sh
# key2pdf / pdftrim を Node 版・Ruby 版の両方で検証する。
# 既定では Keynote を起動しないよう、既知の寸法の PDF を pdflatex で作って入力に使う。
# --with-keynote を付けると Keynote での書き出し（①段）を含む通し確認も行う。
set -u
WITH_KEYNOTE=0
WITH_CLIPBOARD=0
for a in "$@"; do
  case "$a" in
    --with-keynote) WITH_KEYNOTE=1 ;;
    --with-clipboard) WITH_CLIPBOARD=1 ;;  # クリップボードの中身を書き換えるので既定では走らせない
  esac
done

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TMP="$ROOT/tests/tmp"
PASS=0; FAIL=0
LABEL=""

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
skip() { printf '  \033[33m--\033[0m   %s\n' "$1"; }
# UI 操作は環境によって固まることがあるので、必ず時間を区切って呼ぶ
run_limited() { # run_limited <秒> <コマンド...>
  local secs=$1; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  disown "$watcher" 2>/dev/null
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watcher" 2>/dev/null
  return $rc
}
ng()   { FAIL=$((FAIL+1)); printf '  \033[31mNG\033[0m   %s\n' "$1"; }
check() { # check <説明> <条件コマンド...> : 成功を期待する
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ng "$desc"; fi
}
fails() { # fails <説明> <コマンド...> : 失敗を期待する
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ng "$desc"; else ok "$desc"; fi
}

# 出力 PDF の MediaBox 実寸 "幅 高さ" を返す（検証用の物差しは Node 側に統一する）
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

# ---------------------------------------------------------------- フィクスチャ

rm -rf "$TMP"; mkdir -p "$TMP"

# 720x540pt のページに既知寸法の黒矩形を1つずつ置く
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
# 図から離れたところに 0.4bp の点を置いたもの（--noise の検証用）
cat > "$TMP/speck.tex" <<'TEX'
\documentclass{article}
\usepackage[paperwidth=720bp,paperheight=540bp,margin=100bp]{geometry}
\pagestyle{empty}
\begin{document}\noindent
\rule{240bp}{120bp}\hspace{200bp}\rule{0.4bp}{0.4bp}
\end{document}
TEX
echo "フィクスチャを生成中..."
(cd "$TMP" && pdflatex -interaction=batchmode fixture.tex >/dev/null 2>&1)
(cd "$TMP" && pdflatex -interaction=batchmode speck.tex >/dev/null 2>&1)
if [ ! -f "$TMP/fixture.pdf" ] || [ ! -f "$TMP/speck.pdf" ]; then
  echo "pdflatex でフィクスチャを作れませんでした" >&2; exit 1
fi
size_is "フィクスチャ自体は 720x540pt" "$TMP/fixture.pdf" 0 720 540 0.5

# ---------------------------------------------------------------- 本体

# suite <ラベル> <key2pdf のパス> <pdftrim のパス> <作業ディレクトリ>
suite() {
  LABEL=$1; local KEY2PDF=$2 PDFTRIM=$3 W=$4
  rm -rf "$W"; mkdir -p "$W"
  cp "$TMP/fixture.pdf" "$TMP/speck.pdf" "$W/"

  echo "[$LABEL] key2pdf: 基本の切り抜き"
  "$KEY2PDF" -q -o "$W/out" "$W/fixture.pdf"
  size_is "1枚目が矩形の実寸まで縮む" "$W/out/fixture-01.pdf" 0 240 120 2
  size_is "2枚目が矩形の実寸まで縮む" "$W/out/fixture-02.pdf" 0 100 300 2
  check "ページ数は1枚ずつ" test "$(pagecount "$W/out/fixture-01.pdf")" = 1
  "$KEY2PDF" -q -o "$W/m" --margin 5 "$W/fixture.pdf"
  size_is "余白 5pt で縦横とも 10pt 大きい" "$W/m/fixture-01.pdf" 0 250 130 2
  "$KEY2PDF" -q -o "$W/s" --slide 2 --prefix fig "$W/fixture.pdf"
  size_is "--slide 2 は2枚目だけを出す" "$W/s/fig-02.pdf" 0 100 300 2
  check "--slide 2 で1枚目は作られない" test ! -f "$W/s/fig-01.pdf"
  "$KEY2PDF" -q -o "$W/g" --merge "$W/fixture.pdf"
  size_is "--merge 1ページ目" "$W/g/fixture.pdf" 0 240 120 2
  size_is "--merge 2ページ目" "$W/g/fixture.pdf" 1 100 300 2
  "$KEY2PDF" -q -o "$W/n" --bg none "$W/fixture.pdf"
  size_is "--bg none は切り抜かない" "$W/n/fixture-01.pdf" 0 720 540 0.5

  echo "[$LABEL] key2pdf: エラー処理"
  fails "存在しない入力は失敗する" "$KEY2PDF" -q "$W/nope.key"
  fails "未対応の拡張子は失敗する" "$KEY2PDF" -q "$TMP/fixture.tex"
  fails "範囲外のスライドは失敗する" "$KEY2PDF" -q -o "$W/e" --slide 9 "$W/fixture.pdf"
  fails "--slide の書式不正は失敗する" "$KEY2PDF" -q -o "$W/e" --slide "a-b" "$W/fixture.pdf"
  fails "既存ファイルは上書きしない" "$KEY2PDF" -q -o "$W/out" "$W/fixture.pdf"
  check "--force なら上書きする" "$KEY2PDF" -q --force -o "$W/out" "$W/fixture.pdf"

  echo "[$LABEL] pdftrim: PDF の余白削除"
  "$PDFTRIM" -q -o "$W/t/paper-crop.pdf" "$W/fixture.pdf"
  size_is "既定は全ページを個別に切り抜いて1本にまとめる(1p)" "$W/t/paper-crop.pdf" 0 240 120 2
  size_is "同(2p)" "$W/t/paper-crop.pdf" 1 100 300 2
  check "既定の出力名は <名前>-crop.pdf" bash -c '"$0" -q "$1" && test -f "$2"' "$PDFTRIM" "$W/fixture.pdf" "$W/fixture-crop.pdf"
  "$PDFTRIM" -q --uniform -o "$W/t/uni.pdf" "$W/fixture.pdf"
  U1=$(pagesize "$W/t/uni.pdf" 0); U2=$(pagesize "$W/t/uni.pdf" 1)
  check "--uniform は全ページ同じサイズ" test "$U1" = "$U2"
  size_is "--uniform は各ページの和になる" "$W/t/uni.pdf" 0 240 300 2
  "$PDFTRIM" -q --split -o "$W/t/sp" "$W/fixture.pdf"
  size_is "--split は1ページ1ファイル(1枚目)" "$W/t/sp/fixture-01.pdf" 0 240 120 2
  size_is "--split は1ページ1ファイル(2枚目)" "$W/t/sp/fixture-02.pdf" 0 100 300 2
  "$PDFTRIM" -q --pages 2 -o "$W/t/p2.pdf" "$W/fixture.pdf"
  size_is "--pages 2 は2ページ目だけ" "$W/t/p2.pdf" 0 100 300 2
  check "--pages 2 の出力は1ページ" test "$(pagecount "$W/t/p2.pdf")" = 1
  "$PDFTRIM" -q --margin 5 -o "$W/t/m.pdf" "$W/fixture.pdf"
  size_is "--margin 5 で縦横とも 10pt 大きい" "$W/t/m.pdf" 0 250 130 2

  echo "[$LABEL] pdftrim: ゴミ取り (--noise)"
  "$PDFTRIM" -q -o "$W/t/speck-raw.pdf" "$W/speck.pdf"
  local SP SPW; SP=$(pagesize "$W/t/speck-raw.pdf"); SPW=${SP% *}
  if near "$SPW" 240 5; then ng "ゴミが既定で無視されてしまっている（${SPW}pt）"
  else ok "既定ではゴミも内容として拾う（${SPW}pt）"; fi
  "$PDFTRIM" -q --noise 3 -o "$W/t/speck-clean.pdf" "$W/speck.pdf"
  size_is "--noise 3 でゴミを無視して図の実寸になる" "$W/t/speck-clean.pdf" 0 240 120 3

  echo "[$LABEL] pdftrim: エラー処理"
  fails "PDF 以外は失敗する" "$PDFTRIM" -q "$TMP/fixture.tex"
  fails "入力と同じファイルへの出力は失敗する" "$PDFTRIM" -q -o "$W/fixture.pdf" "$W/fixture.pdf"
  fails "既存ファイルは上書きしない" "$PDFTRIM" -q -o "$W/t/m.pdf" "$W/fixture.pdf"
  check "--force なら上書きする" "$PDFTRIM" -q --force -o "$W/t/m.pdf" "$W/fixture.pdf"

  echo "[$LABEL] TeX に貼れるか"
  cat > "$W/use.tex" <<'TEX'
\documentclass{article}
\usepackage{graphicx}
\begin{document}
\includegraphics[width=0.8\linewidth]{out/fixture-01.pdf}
\includegraphics[width=3cm]{out/fixture-02.pdf}
\end{document}
TEX
  check "pdflatex で \\includegraphics が通る" bash -c "cd '$W' && pdflatex -interaction=batchmode use.tex"

  if [ "$WITH_KEYNOTE" = 1 ]; then
    echo "[$LABEL] Keynote からの通し確認"
    local SAMPLE="$W/sample.key"
    if run_limited 120 osascript tests/make_sample_key.applescript "$SAMPLE" && [ -e "$SAMPLE" ]; then
      ok "サンプル .key を生成した"
      if "$KEY2PDF" -q -o "$W/key" "$SAMPLE"; then
        ok ".key から PDF を書き出して切り抜いた"
        for n in 01 02; do
          local f="$W/key/sample-$n.pdf"
          if [ -f "$f" ]; then
            local s w h; s=$(pagesize "$f"); w=${s% *}; h=${s#* }
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
    # 使い終わった書類が残っていると次の操作が詰まるので閉じておく
    osascript -e 'tell application "Keynote"
	repeat while (count of documents) > 0
		close document 1 saving no
	end repeat
end tell' >/dev/null 2>&1
  fi
}

# 画像として埋め込まれていないか（ベクタのままか）
is_vector() {
  ! grep -qa "/Subtype */Image" "$1"
}

# ページ全面を白で塗る指示が入っているか（CGPDFContext は "1 sc 0 0 W H re f" を出す）
has_white_backing() {
  /usr/bin/ruby -e '
require "zlib"
body = File.binread(ARGV[0]).scan(/stream\r?\n(.*?)endstream/m).flatten
          .map { |x| (Zlib::Inflate.inflate(x) rescue nil) }.compact.join(" ")
exit(body =~ /(1 sc|1 1 1 rg)\s+0 0 [\d.]+ [\d.]+ re\s+f/ ? 0 : 1)' "$1"
}

# ---------------------------------------------------------------- clip2pdf（アプリ）

# アプリ本体の切り抜きは CLI と同じ結果になるはず。GUI は出さずに検証する。
clip2pdf_suite() {
  LABEL="clip2pdf"
  local BIN="$ROOT/app/build/clip2pdf.app/Contents/MacOS/clip2pdf"
  local W="$TMP/app"
  mkdir -p "$W"
  if [ ! -x "$BIN" ]; then
    echo "[clip2pdf] ビルドしています…"
    if ! "$ROOT/app/build.sh" >/dev/null 2>&1; then
      ng "clip2pdf のビルドに失敗した"; return
    fi
  fi
  ok "clip2pdf をビルドできている"

  echo "[clip2pdf] 切り抜き（CLI 版と同じ結果になるか）"
  "$BIN" --trim "$TMP/fixture.pdf" "$W/trim.pdf" 2>/dev/null
  size_is "1ページ目が CLI 版と同じ寸法" "$W/trim.pdf" 0 241.44 121.44 0.01
  size_is "2ページ目が CLI 版と同じ寸法" "$W/trim.pdf" 1 101.28 301.44 0.01
  "$BIN" --trim "$TMP/fixture.pdf" "$W/margin.pdf" --margin 5 2>/dev/null
  size_is "--margin 5 で縦横とも 10pt 大きい" "$W/margin.pdf" 0 251.44 131.44 0.01
  "$BIN" --trim "$TMP/fixture.pdf" "$W/raw.pdf" --no-trim 2>/dev/null
  size_is "--no-trim は切り抜かない" "$W/raw.pdf" 0 720 540 0.5
  fails "読めない入力は失敗する" "$BIN" --trim "$TMP/nope.pdf" "$W/x.pdf"

  echo "[clip2pdf] ファイルの変換（key2pdf / pdftrim 相当）"
  mkdir -p "$W/conv"
  "$BIN" --convert "$TMP/fixture.pdf" "$W/conv" >/dev/null 2>&1
  size_is "PDF をページごとに書き出す(1枚目)" "$W/conv/fixture-01.pdf" 0 241.44 121.44 0.01
  size_is "同(2枚目)" "$W/conv/fixture-02.pdf" 0 101.28 301.44 0.01
  "$BIN" --convert "$TMP/fixture.pdf" "$W/conv-merge" --merge >/dev/null 2>&1
  check "--merge は1本にまとまる" test "$(pagecount "$W/conv-merge/fixture-01.pdf")" = 2
  fails "存在しないファイルは失敗する" "$BIN" --convert "$TMP/nope.pdf" "$W/conv"

  echo "[clip2pdf] 背景の切り替え"
  "$BIN" --trim "$TMP/fixture.pdf" "$W/white.pdf" --background white 2>/dev/null
  size_is "白地にしても寸法は変わらない" "$W/white.pdf" 0 241.44 121.44 0.01
  check "--background white はページ全面に白を敷く" has_white_backing "$W/white.pdf"
  fails "既定（透明）は白を敷かない" has_white_backing "$W/trim.pdf"

  if [ "$WITH_CLIPBOARD" = 1 ]; then
    echo "[clip2pdf] クリップボード経由（クリップボードの中身を書き換えます）"
    if "$ROOT/tests/setclip" "$TMP/fixture.pdf" >/dev/null 2>&1 \
       && "$BIN" --clipboard "$W/clip.pdf" 2>/dev/null; then
      size_is "クリップボードの図を切り抜いて保存できる" "$W/clip.pdf" 0 241.44 121.44 0.01
    else
      ng "クリップボード経由の変換に失敗した"
    fi

    if [ "$WITH_KEYNOTE" = 1 ]; then
      echo "[clip2pdf] .key ファイルの変換"
      if run_limited 120 osascript tests/make_sample_key.applescript "$W/drop.key"; then
        mkdir -p "$W/dropout"
        if run_limited 120 "$BIN" --convert "$W/drop.key" "$W/dropout"; then
          size_is "スライド1が図の実寸まで縮む" "$W/dropout/drop-01.pdf" 0 99.84 24.96 4
          size_is "スライド2が図の実寸まで縮む" "$W/dropout/drop-02.pdf" 0 97.92 24.96 4
          check "ベクタのまま" is_vector "$W/dropout/drop-01.pdf"
        else
          ng ".key の変換に失敗した"
        fi
      else
        skip ".key の変換用サンプルを作れませんでした"
      fi
      osascript -e 'tell application "Keynote"
	repeat while (count of documents) > 0
		close document 1 saving no
	end repeat
end tell' >/dev/null 2>&1

      # Keynote はクリップボードに PDF を載せないので、貼り戻してベクタ化する経路を確かめる
      echo "[clip2pdf] Keynote からコピーして取り出す"
      if run_limited 120 osascript tests/make_sample_key.applescript "$W/sample.key" \
         && run_limited 90 osascript tests/copy_from_keynote.applescript "$W/sample.key"; then
        ok "Keynote の図をコピーできた"
        if "$BIN" --clipboard "$W/kn-vector.pdf" --keynote 2>/dev/null; then
          size_is "ベクタで取り出せる" "$W/kn-vector.pdf" 0 99.84 24.96 4
          check "画像化されていない" is_vector "$W/kn-vector.pdf"
        else
          ng "Keynote 経由の取り出しに失敗した"
        fi
        if "$BIN" --clipboard "$W/kn-image.pdf" 2>/dev/null; then
          size_is "画像としても取り出せる" "$W/kn-image.pdf" 0 99.84 24.96 4
          fails "画像経路は画像として入る" is_vector "$W/kn-image.pdf"
        else
          ng "画像経路の取り出しに失敗した"
        fi
      else
        # キー操作やメニュー操作の許可は環境差が大きいので、失敗は落とさずスキップ扱いにする
        skip "Keynote からのコピーを実行できませんでした（アクセシビリティの許可を確認してください）"
        osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
      fi
    fi
  fi
}

suite "Node" "$ROOT/key2pdf" "$ROOT/pdftrim" "$TMP/node"
suite "Ruby" "$ROOT/ruby/key2pdf" "$ROOT/ruby/pdftrim" "$TMP/ruby"
clip2pdf_suite

echo
printf '成功 %d / 失敗 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
