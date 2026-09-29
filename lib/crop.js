'use strict';
// key2pdf / pdftrim の共通処理。
// PDF のページをラスタ化して「背景色と異なる画素」の範囲を求め、
// ページ矩形(MediaBox/CropBox)をそこまで切り詰める。内容は再エンコードしない。

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { PDFDocument, PDFName } = require('pdf-lib');

const MAX_RASTER_PX = 8000; // ラスタ化時の1辺の上限。超えるなら dpi を自動で下げる

const state = { prog: 'key2pdf', verbose: false, quiet: false };

function configure(opts) {
  Object.assign(state, opts);
}

const info = (msg) => { if (!state.quiet) process.stderr.write(`${msg}\n`); };
const debug = (msg) => { if (state.verbose && !state.quiet) process.stderr.write(`  ${msg}\n`); };
const warn = (msg) => process.stderr.write(`${state.prog}: 警告: ${msg}\n`);

function die(msg) {
  process.stderr.write(`${state.prog}: エラー: ${msg}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------- ラスタ化

function findGs() {
  for (const cand of ['gs', '/usr/local/bin/gs', '/opt/homebrew/bin/gs']) {
    const r = spawnSync(cand, ['--version'], { encoding: 'utf8' });
    if (!r.error && r.status === 0) return cand;
  }
  die('Ghostscript (gs) が見つかりません。`brew install ghostscript` などで導入してください。');
}

// gs にページを PPM(P6) で吐かせる。生の RGB なので依存なしで読める。
function renderPage(gs, pdf, pageNo, dpi, outPpm) {
  const args = [
    '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
    '-sDEVICE=ppmraw', `-r${dpi}`,
    `-dFirstPage=${pageNo}`, `-dLastPage=${pageNo}`,
    '-dUseCropBox', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
    `-sOutputFile=${outPpm}`, pdf,
  ];
  debug(`gs ${args.join(' ')}`);
  const r = spawnSync(gs, args, { encoding: 'utf8' });
  if (r.status !== 0 || !fs.existsSync(outPpm)) {
    die(`ページ ${pageNo} のラスタ化に失敗しました。\n  ${(r.stderr || r.stdout || '').trim()}`);
  }
}

// P6 ヘッダ（マジック・幅・高さ・最大値。間に空白とコメントを挟める）を読む
function parsePpm(buf) {
  let pos = 0;
  const token = () => {
    while (pos < buf.length) {
      const c = buf[pos];
      if (c === 0x23) { while (pos < buf.length && buf[pos] !== 0x0a) pos++; }
      else if (c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d) pos++;
      else break;
    }
    const start = pos;
    while (pos < buf.length && ![0x20, 0x09, 0x0a, 0x0d].includes(buf[pos])) pos++;
    return buf.toString('latin1', start, pos);
  };
  const magic = token();
  if (magic !== 'P6') die(`ラスタ画像を読めませんでした（P6 ではなく ${magic}）`);
  const width = parseInt(token(), 10);
  const height = parseInt(token(), 10);
  const maxval = parseInt(token(), 10);
  if (maxval !== 255) die(`対応していない PPM です（maxval=${maxval}）`);
  pos++; // ヘッダ直後の空白1文字
  return { width, height, offset: pos };
}

function parseBg(spec) {
  if (spec === 'auto') return null;
  const m = /^#?([0-9a-fA-F]{6})$/.exec(spec);
  if (!m) die(`--bg には auto か #RRGGBB を指定してください: ${JSON.stringify(spec)}`);
  const h = m[1];
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}

// 背景色と異なる画素の bbox を {left, upper, right, lower}（右下は排他）で返す。無地なら null。
// noise を指定すると、差分画素がその数以下の行・列は内容とみなさない（ゴミ取り）。
function detectBbox(ppmPath, bgSpec, tolerance, noise = 0) {
  const buf = fs.readFileSync(ppmPath);
  const { width, height, offset } = parsePpm(buf);

  let bg = bgSpec;
  if (!bg) {
    // 四隅の多数決。割れたら左上を採用する。
    const at = (x, y) => {
      const i = offset + (y * width + x) * 3;
      return [buf[i], buf[i + 1], buf[i + 2]];
    };
    const corners = [at(0, 0), at(width - 1, 0), at(0, height - 1), at(width - 1, height - 1)];
    const tally = new Map();
    for (const c of corners) {
      const k = c.join(',');
      tally.set(k, (tally.get(k) || 0) + 1);
    }
    let best = corners[0], bestN = 0;
    for (const c of corners) {
      const n = tally.get(c.join(','));
      if (n > bestN) { best = c; bestN = n; }
    }
    bg = best;
    debug(`背景色を推定: #${bg.map((v) => v.toString(16).padStart(2, '0')).join('')}`);
  }
  const [br, bgc, bb] = bg;

  const rows = new Int32Array(height);
  const cols = new Int32Array(width);
  for (let y = 0; y < height; y++) {
    let i = offset + y * width * 3;
    for (let x = 0; x < width; x++, i += 3) {
      if (Math.abs(buf[i] - br) > tolerance
       || Math.abs(buf[i + 1] - bgc) > tolerance
       || Math.abs(buf[i + 2] - bb) > tolerance) {
        rows[y]++;
        cols[x]++;
      }
    }
  }
  const firstOver = (arr) => { for (let i = 0; i < arr.length; i++) if (arr[i] > noise) return i; return -1; };
  const lastOver = (arr) => { for (let i = arr.length - 1; i >= 0; i--) if (arr[i] > noise) return i; return -1; };

  const upper = firstOver(rows);
  if (upper < 0) return { bbox: null, width, height };
  return {
    bbox: { left: firstOver(cols), upper, right: lastOver(cols) + 1, lower: lastOver(rows) + 1 },
    width,
    height,
  };
}

// ---------------------------------------------------------------- 切り抜き範囲

// 1ページ分の切り抜き範囲を PDF 座標 {x, y, width, height} で返す。
// 切り抜けないときは null（そのページは元のまま出す）。
function detectCropBox(opts) {
  const { gs, pdf, page, pageNo, dpi: wantDpi, margin, bg, tolerance, noise, tmpdir, label } = opts;
  const name = label || `ページ ${pageNo}`;
  const ref = page.getCropBox();
  const x0 = ref.x, y0 = ref.y;
  const x1 = ref.x + ref.width, y1 = ref.y + ref.height;

  const rot = ((page.getRotation().angle % 360) + 360) % 360;
  if (rot !== 0) {
    warn(`${name}: /Rotate ${rot} のページは切り抜きをスキップします`);
    return null;
  }

  let dpi = wantDpi;
  const longestPt = Math.max(ref.width, ref.height);
  if ((longestPt * dpi) / 72 > MAX_RASTER_PX) {
    dpi = Math.max(12, Math.floor((MAX_RASTER_PX * 72) / longestPt));
    warn(`ページが大きいため検出解像度を ${dpi} dpi に下げました`);
  }

  const ppm = path.join(tmpdir, `page-${pageNo}.ppm`);
  renderPage(gs, pdf, pageNo, dpi, ppm);
  const { bbox, width: imgW, height: imgH } = detectBbox(ppm, bg, tolerance, noise);
  fs.rmSync(ppm, { force: true });

  if (!bbox) {
    warn(`${name}: 背景色以外の内容がありません。切り抜かずに出力します`);
    return null;
  }

  // アンチエイリアスの端が欠けないよう 1px 外に広げる
  const left = Math.max(0, bbox.left - 1);
  const upper = Math.max(0, bbox.upper - 1);
  const right = Math.min(imgW, bbox.right + 1);
  const lower = Math.min(imgH, bbox.lower + 1);
  if (left === 0 && upper === 0 && right === imgW && lower === imgH) {
    warn(`${name}: ページ全体が内容と判定され切り抜けませんでした。`
       + '背景が塗り・画像・グラデーションの可能性があります'
       + '（--bg で背景色を指定するか --tolerance を上げてください）');
  }

  const s = 72 / dpi;
  const nx0 = Math.max(x0, x0 + left * s - margin);
  const nx1 = Math.min(x1, x0 + right * s + margin);
  // 画像は上が原点、PDF は下が原点
  const ny1 = Math.min(y1, y1 - upper * s + margin);
  const ny0 = Math.max(y0, y1 - lower * s - margin);
  debug(`${name}: ${ref.width.toFixed(1)}x${ref.height.toFixed(1)}pt → `
      + `${(nx1 - nx0).toFixed(1)}x${(ny1 - ny0).toFixed(1)}pt`);
  return { x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0 };
}

// 複数ページの範囲をひとつにまとめる（--uniform 用）
function unionBoxes(boxes) {
  const valid = boxes.filter(Boolean);
  if (valid.length === 0) return null;
  const x0 = Math.min(...valid.map((b) => b.x));
  const y0 = Math.min(...valid.map((b) => b.y));
  const x1 = Math.max(...valid.map((b) => b.x + b.width));
  const y1 = Math.max(...valid.map((b) => b.y + b.height));
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}

// ---------------------------------------------------------------- 出力

function applyBox(page, box) {
  if (!box) return;
  page.setMediaBox(box.x, box.y, box.width, box.height);
  page.setCropBox(box.x, box.y, box.width, box.height);
  for (const key of ['BleedBox', 'TrimBox', 'ArtBox']) {
    if (page.node.get(PDFName.of(key))) {
      page[`set${key}`](box.x, box.y, box.width, box.height);
    }
  }
}

// items: [{ pageNo, box }] を1本の PDF として書き出す
async function writePdf(srcDoc, items, file) {
  const out = await PDFDocument.create();
  const copied = await out.copyPages(srcDoc, items.map((it) => it.pageNo - 1));
  copied.forEach((page, i) => {
    out.addPage(page);
    applyBox(page, items[i].box);
  });
  fs.writeFileSync(file, await out.save());
}

// ---------------------------------------------------------------- 雑多

// "1,3-5" のような指定を 1 始まりのページ番号リストにする
function parsePageSpec(spec, total, optName) {
  if (!spec) return Array.from({ length: total }, (_, i) => i + 1);
  const out = [];
  for (const raw of spec.split(',')) {
    const part = raw.trim();
    if (!part) continue;
    const m = /^(\d+)(?:-(\d+))?$/.exec(part);
    if (!m) die(`${optName} の書式が不正です: ${JSON.stringify(part)}（例: 1,3-5）`);
    const a = parseInt(m[1], 10);
    const b = m[2] ? parseInt(m[2], 10) : a;
    if (a < 1 || b < a) die(`${optName} の範囲が不正です: ${JSON.stringify(part)}`);
    for (let n = a; n <= b; n++) out.push(n);
  }
  const over = out.find((n) => n > total);
  if (over !== undefined) die(`${over} ページ目は存在しません（全 ${total} ページ）`);
  return [...new Set(out)];
}

function num(value, name, { int = false, min = -Infinity, max = Infinity } = {}) {
  const n = int ? Number.parseInt(value, 10) : Number.parseFloat(value);
  if (!Number.isFinite(n) || (int && String(n) !== String(value).trim())) {
    die(`${name} には数値を指定してください: ${JSON.stringify(value)}`);
  }
  if (n < min || n > max) die(`${name} は ${min}-${max} の範囲で指定してください`);
  return n;
}

function expandHome(p) {
  return p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
}

module.exports = {
  configure, info, debug, warn, die,
  findGs, renderPage, parsePpm, parseBg, detectBbox,
  detectCropBox, unionBoxes, applyBox, writePdf,
  parsePageSpec, num, expandHome,
};
