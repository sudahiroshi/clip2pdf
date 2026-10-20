# frozen_string_literal: true

# key2pdf / pdftrim（Ruby 版）の共通処理。
#
# ページを Ghostscript でラスタ化して「背景色と異なる画素」の範囲を求め、
# その範囲だけを pdfTeX で切り出す。元ページは Form XObject としてそのまま
# 埋め込まれるので、中身は無劣化（ベクタのまま）。

require 'fileutils'
require 'open3'
require 'tmpdir'

module Crop
  MAX_RASTER_PX = 8000 # ラスタ化時の1辺の上限。超えるなら dpi を自動で下げる

  module_function

  # ---------------------------------------------------------------- 出力

  @prog = 'key2pdf'
  @verbose = false
  @quiet = false

  def configure(prog: nil, verbose: nil, quiet: nil)
    @prog = prog unless prog.nil?
    @verbose = verbose unless verbose.nil?
    @quiet = quiet unless quiet.nil?
  end

  def info(msg)
    warn_out(msg) unless @quiet
  end

  def debug(msg)
    warn_out("  #{msg}") if @verbose && !@quiet
  end

  def warning(msg)
    warn_out("#{@prog}: 警告: #{msg}")
  end

  def die(msg)
    warn_out("#{@prog}: エラー: #{msg}")
    exit 1
  end

  def warn_out(msg)
    $stderr.puts(msg)
  end

  # ---------------------------------------------------------------- 外部コマンド

  def find_cmd(name, extra = [])
    ([name] + extra).each do |cand|
      out, _err, st = Open3.capture3(cand, '--version')
      return cand if st.success? && !out.nil?
    rescue Errno::ENOENT
      next
    end
    nil
  end

  def find_gs
    find_cmd('gs', ['/usr/local/bin/gs', '/opt/homebrew/bin/gs']) ||
      die('Ghostscript (gs) が見つかりません。`brew install ghostscript` などで導入してください。')
  end

  def find_pdftex
    find_cmd('pdftex', ['/usr/local/texlive/2024/bin/universal-darwin/pdftex', '/Library/TeX/texbin/pdftex']) ||
      die('pdftex が見つかりません。MacTeX / TeX Live を導入してください。')
  end

  # ---------------------------------------------------------------- ラスタ化

  # gs にページを PPM(P6) で吐かせる。生の RGB なので依存なしで読める。
  def render_page(gs, pdf, page_no, dpi, out_ppm)
    args = [
      '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
      '-sDEVICE=ppmraw', "-r#{dpi}",
      "-dFirstPage=#{page_no}", "-dLastPage=#{page_no}",
      '-dUseCropBox', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
      "-sOutputFile=#{out_ppm}", pdf
    ]
    debug("gs #{args.join(' ')}")
    out, err, st = Open3.capture3(gs, *args)
    return if st.success? && File.exist?(out_ppm)

    die("ページ #{page_no} のラスタ化に失敗しました。\n  #{(err.to_s + out.to_s).strip}")
  end

  # P6 ヘッダ（マジック・幅・高さ・最大値。間に空白とコメントを挟める）を読む
  def parse_ppm(data)
    pos = 0
    token = lambda do
      while pos < data.bytesize
        c = data.getbyte(pos)
        if c == 0x23 # '#' コメント
          pos += 1 while pos < data.bytesize && data.getbyte(pos) != 0x0A
        elsif [0x20, 0x09, 0x0A, 0x0D].include?(c)
          pos += 1
        else
          break
        end
      end
      start = pos
      pos += 1 while pos < data.bytesize && ![0x20, 0x09, 0x0A, 0x0D].include?(data.getbyte(pos))
      data.byteslice(start, pos - start)
    end

    magic = token.call
    die("ラスタ画像を読めませんでした（P6 ではなく #{magic}）") unless magic == 'P6'
    width = token.call.to_i
    height = token.call.to_i
    maxval = token.call.to_i
    die("対応していない PPM です（maxval=#{maxval}）") unless maxval == 255
    pos += 1 # ヘッダ直後の空白1文字
    [width, height, pos]
  end

  def parse_bg(spec)
    return nil if spec == 'auto'

    m = /\A#?([0-9a-fA-F]{6})\z/.match(spec)
    die("--bg には auto か #RRGGBB を指定してください: #{spec.inspect}") unless m
    [0, 2, 4].map { |i| m[1][i, 2].to_i(16) }
  end

  # 画素1つ分（3バイト）が背景色の範囲に収まるかを見る正規表現を作る
  def pixel_regex(lo, hi)
    cls = (0..2).map { |i| format('[\\x%02X-\\x%02X]', lo[i], hi[i]) }.join
    # \xNN を含むのでバイナリ文字列として組む（UTF-8 のままだと不正なエスケープになる）
    Regexp.new("\\A(?:#{cls})*".b)
  end

  def estimate_bg(data, width, height, offset)
    at = lambda do |x, y|
      i = offset + ((y * width) + x) * 3
      [data.getbyte(i), data.getbyte(i + 1), data.getbyte(i + 2)]
    end
    corners = [at.call(0, 0), at.call(width - 1, 0), at.call(0, height - 1), at.call(width - 1, height - 1)]
    tally = Hash.new(0)
    corners.each { |c| tally[c] += 1 }
    bg = corners.max_by { |c| tally[c] }
    debug(format('背景色を推定: #%02x%02x%02x', *bg))
    bg
  end

  # 背景色と異なる画素の bbox を {left:, upper:, right:, lower:}（右下は排他）で返す。無地なら nil。
  # noise を指定すると、差分画素がその数以下の行・列は内容とみなさない（ゴミ取り）。
  def detect_bbox(ppm_path, bg_spec, tolerance, noise = 0)
    data = File.binread(ppm_path)
    width, height, offset = parse_ppm(data)
    bg = bg_spec || estimate_bg(data, width, height, offset)
    rowlen = width * 3
    rows = (0...height).map { |y| data.byteslice(offset + (y * rowlen), rowlen) }
    if noise.zero?
      bbox_fast(rows, width, bg, tolerance)
    else
      bbox_with_noise(rows, width, bg, tolerance, noise)
    end.then { |bbox| [bbox, width, height] }
  end

  # 既定の経路。行の先頭・末尾の背景画素の連なりを正規表現で一気に飛ばすので、
  # 画素ループを Ruby で回さずに済む。
  def bbox_fast(rows, width, bg, tolerance)
    lo = bg.map { |v| [v - tolerance, 0].max }
    hi = bg.map { |v| [v + tolerance, 255].min }
    fwd = pixel_regex(lo, hi)
    rev = pixel_regex(lo.reverse, hi.reverse) # 反転した行は画素内の並びも B,G,R になる

    top = nil
    bottom = nil
    left = width
    right = -1
    rows.each_with_index do |row, y|
      lead = fwd.match(row)[0].bytesize / 3
      next if lead >= width

      trail = rev.match(row.reverse)[0].bytesize / 3
      top ||= y
      bottom = y
      left = lead if lead < left
      r = width - trail
      right = r if r > right
    end
    return nil if top.nil?

    { left: left, upper: top, right: right, lower: bottom + 1 }
  end

  # --noise 指定時の経路。行・列ごとに差分画素を数えるため画素を1つずつ見る（その分遅い）。
  def bbox_with_noise(rows, width, bg, tolerance, noise)
    br, bgc, bb = bg
    bgrow = [br, bgc, bb].pack('C3') * width
    row_count = Array.new(rows.size, 0)
    col_count = Array.new(width, 0)
    rows.each_with_index do |row, y|
      next if row == bgrow

      bytes = row.unpack('C*')
      x = 0
      while x < width
        i = x * 3
        if (bytes[i] - br).abs > tolerance ||
           (bytes[i + 1] - bgc).abs > tolerance ||
           (bytes[i + 2] - bb).abs > tolerance
          row_count[y] += 1
          col_count[x] += 1
        end
        x += 1
      end
    end
    first_over = ->(arr) { arr.index { |n| n > noise } }
    last_over = ->(arr) { arr.rindex { |n| n > noise } }
    upper = first_over.call(row_count)
    return nil if upper.nil?

    { left: first_over.call(col_count), upper: upper,
      right: last_over.call(col_count) + 1, lower: last_over.call(row_count) + 1 }
  end

  # ---------------------------------------------------------------- 切り抜き範囲

  # 1ページ分の切り抜き範囲を [llx, lly, urx, ury]（bp、ページ左下が原点）で返す。
  # 切り抜けないときは nil（そのページは元のまま出す）。
  def detect_crop_box(gs:, pdf:, page_no:, dpi:, margin:, bg:, tolerance:, noise:, tmpdir:, label: nil)
    name = label || "ページ #{page_no}"
    ppm = File.join(tmpdir, "page-#{page_no}.ppm")
    render_page(gs, pdf, page_no, dpi, ppm)
    bbox, img_w, img_h = detect_bbox(ppm, bg, tolerance, noise)
    FileUtils.rm_f(ppm)

    page_w = img_w * 72.0 / dpi
    page_h = img_h * 72.0 / dpi
    if bbox.nil?
      warning("#{name}: 背景色以外の内容がありません。切り抜かずに出力します")
      return nil
    end

    # アンチエイリアスの端が欠けないよう 1px 外に広げる
    left = [0, bbox[:left] - 1].max
    upper = [0, bbox[:upper] - 1].max
    right = [img_w, bbox[:right] + 1].min
    lower = [img_h, bbox[:lower] + 1].min
    if left.zero? && upper.zero? && right == img_w && lower == img_h
      warning("#{name}: ページ全体が内容と判定され切り抜けませんでした。" \
              '背景が塗り・画像・グラデーションの可能性があります' \
              '（--bg で背景色を指定するか --tolerance を上げてください）')
    end

    s = 72.0 / dpi
    llx = [0.0, (left * s) - margin].max
    urx = [page_w, (right * s) + margin].min
    # 画像は上が原点、PDF は下が原点
    ury = [page_h, page_h - (upper * s) + margin].min
    lly = [0.0, page_h - (lower * s) - margin].max
    debug(format('%s: %.1fx%.1fpt → %.1fx%.1fpt', name, page_w, page_h, urx - llx, ury - lly))
    [llx, lly, urx, ury]
  end

  # 複数ページの範囲をひとつにまとめる（--uniform 用）
  def union_boxes(boxes)
    valid = boxes.compact
    return nil if valid.empty?

    [valid.map { |b| b[0] }.min, valid.map { |b| b[1] }.min,
     valid.map { |b| b[2] }.max, valid.map { |b| b[3] }.max]
  end

  # ---------------------------------------------------------------- 出力

  # 入力 PDF のバージョン（例: [1, 7]）。pdfTeX は自分より新しい PDF を取り込めないため、
  # 取り込む前に \pdfmajorversion / \pdfminorversion を合わせておく。
  def pdf_version(pdf)
    head = File.binread(pdf, 16).to_s
    m = /%PDF-(\d)\.(\d)/.match(head)
    m ? [m[1].to_i, m[2].to_i] : [1, 7]
  end

  # items: [{ page_no:, box: [llx,lly,urx,ury] | nil }] を1本の PDF として書き出す。
  # pdfTeX が元ページを Form XObject としてそのまま埋め込むので中身は無劣化。
  def write_pdf(pdftex, src_pdf, items, out_file)
    major, minor = pdf_version(src_pdf)
    Dir.mktmpdir('key2pdf-tex-') do |dir|
      # TeX にパスを渡すと空白や特殊文字で壊れるので、固定名でコピーして持ち込む
      FileUtils.cp(src_pdf, File.join(dir, 'input.pdf'))
      body = items.map do |it|
        if it[:box]
          format("\\page %d [%.4f %.4f %.4f %.4f]\n", it[:page_no], *it[:box])
        else
          format("\\pagefull{%d}\n", it[:page_no])
        end
      end.join
      File.write(File.join(dir, 'job.tex'), tex_source(major, minor, body))
      out, err, st = Open3.capture3(pdftex, '-interaction=nonstopmode', '-halt-on-error', 'job.tex',
                                    chdir: dir)
      result = File.join(dir, 'job.pdf')
      unless st.success? && File.exist?(result)
        log = File.exist?(File.join(dir, 'job.log')) ? File.read(File.join(dir, 'job.log')) : ''
        detail = log.lines.grep(/^!/).first(5).join.strip
        detail = (err.to_s + out.to_s).strip if detail.empty?
        die("pdftex での書き出しに失敗しました。\n  #{detail}")
      end
      FileUtils.mkdir_p(File.dirname(out_file))
      FileUtils.cp(result, out_file)
    end
  end

  # pdfcrop と同じ要領で、元ページを XObject として取り込み、ページ矩形だけを付け替える
  def tex_source(major, minor, body)
    <<~TEX
      \\pdfoutput=1
      \\pdfcompresslevel=9
      \\ifx\\pdfmajorversion\\undefined \\pdfminorversion=#{minor}
      \\else \\pdfmajorversion=#{major} \\pdfminorversion=#{minor} \\fi
      \\def\\pdffile{input.pdf}
      % \\page <ページ番号> [左 下 右 上]（bp、ページ左下が原点）
      \\def\\page #1 [#2 #3 #4 #5]{%
        \\setbox0=\\hbox{\\pdfximage page #1 cropbox{\\pdffile}\\pdfrefximage\\pdflastximage}%
        \\pdfhorigin=-#2bp\\relax
        \\pdfvorigin=#3bp\\relax
        \\pdfpagewidth=#4bp\\relax \\advance\\pdfpagewidth by -#2bp\\relax
        \\pdfpageheight=#5bp\\relax \\advance\\pdfpageheight by -#3bp\\relax
        \\ht0=\\pdfpageheight
        \\shipout\\box0\\relax
      }
      % 切り抜かずにそのまま1ページ出す
      \\def\\pagefull#1{%
        \\setbox0=\\hbox{\\pdfximage page #1 cropbox{\\pdffile}\\pdfrefximage\\pdflastximage}%
        \\pdfhorigin=0pt\\relax \\pdfvorigin=0pt\\relax
        \\pdfpagewidth=\\wd0 \\pdfpageheight=\\ht0
        \\shipout\\box0\\relax
      }
      #{body}\\end
    TEX
  end

  # ---------------------------------------------------------------- 雑多

  # pdfTeX に数えさせる（gs を -dNOSAFER で動かさずに済む）
  def page_count(pdftex, pdf)
    Dir.mktmpdir('key2pdf-count-') do |dir|
      FileUtils.cp(pdf, File.join(dir, 'input.pdf'))
      major, minor = pdf_version(pdf)
      src = <<~TEX
        \\pdfoutput=1
        \\ifx\\pdfmajorversion\\undefined \\pdfminorversion=#{minor}
        \\else \\pdfmajorversion=#{major} \\pdfminorversion=#{minor} \\fi
        \\pdfximage page 1 cropbox{input.pdf}
        \\immediate\\write17{K2P-PAGES=\\the\\pdflastximagepages}
        \\end
      TEX
      File.write(File.join(dir, 'count.tex'), src)
      out, _err, _st = Open3.capture3(pdftex, '-interaction=nonstopmode', 'count.tex', chdir: dir)
      log = File.join(dir, 'count.log')
      text = out.to_s + (File.exist?(log) ? File.read(log) : '')
      m = /K2P-PAGES=(\d+)/.match(text)
      die("PDF のページ数を取得できませんでした: #{File.basename(pdf)}") unless m
      m[1].to_i
    end
  end

  # "1,3-5" のような指定を 1 始まりのページ番号リストにする
  def parse_page_spec(spec, total, opt_name)
    return (1..total).to_a if spec.nil? || spec.empty?

    out = []
    spec.split(',').each do |raw|
      part = raw.strip
      next if part.empty?

      m = /\A(\d+)(?:-(\d+))?\z/.match(part)
      die("#{opt_name} の書式が不正です: #{part.inspect}（例: 1,3-5）") unless m

      a = m[1].to_i
      b = m[2] ? m[2].to_i : a
      die("#{opt_name} の範囲が不正です: #{part.inspect}") if a < 1 || b < a

      out.concat((a..b).to_a)
    end
    over = out.find { |n| n > total }
    die("#{over} ページ目は存在しません（全 #{total} ページ）") if over
    out.uniq
  end

  def num(value, name, int: false, min: -Float::INFINITY, max: Float::INFINITY)
    str = value.to_s.strip
    ok = int ? /\A-?\d+\z/.match?(str) : /\A-?\d+(\.\d+)?\z/.match?(str)
    die("#{name} には数値を指定してください: #{value.inspect}") unless ok

    n = int ? str.to_i : str.to_f
    die("#{name} は #{min}-#{max} の範囲で指定してください") if n < min || n > max
    n
  end

  def expand_home(path)
    path.start_with?('~/') ? File.join(Dir.home, path[2..]) : path
  end
end
