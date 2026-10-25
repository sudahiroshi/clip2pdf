// clip2pdf — クリップボードの図を PDF として保存するアプリ。
//
// Keynote で図をコピーすると、クリップボードにベクタの PDF（com.adobe.pdf）が載る。
// このアプリに切り替えて ⌘V すると、それを取り出して余白を落とし、PDF として保存する。
//
// 切り抜きは Quartz でページをラスタ化して「内容のある範囲」を求め、PDFKit で
// ページ矩形（MediaBox/CropBox）を付け替える方式。中身は再描画しないのでベクタのまま。
// CLI の key2pdf / pdftrim と同じ考え方・同じ結果になる。

import AppKit
import ApplicationServices
import PDFKit

// ---------------------------------------------------------------- 切り抜き

struct TrimOptions {
    var margin: CGFloat = 0      // 残す余白 pt
    var dpi: CGFloat = 150       // 判定に使うラスタ解像度
    var tolerance: Int = 8       // 背景とみなす色差 0-255
}

enum Trim {
    /// 1ページ分の切り抜き範囲をページ座標で返す。切り抜けないときは nil。
    static func cropRect(for page: PDFPage, options: TrimOptions) -> CGRect? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // 大きすぎるページは解像度を落として判定する
        var scale = options.dpi / 72.0
        let longest = max(bounds.width, bounds.height) * scale
        if longest > 8000 { scale = 8000 / max(bounds.width, bounds.height) }

        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceDeviceRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 透明な下地に描く。何も塗られていない部分は alpha=0 になる
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // まず「塗られているか（alpha>0）」で見る。Keynote からコピーした図は背景が
        // 透明なのでこれで足りる。ページ全面が塗られていたら背景色との差で見直す。
        var box = scanBBox(buf, w, h) { px in px[3] > 0 }
        if box == nil { return nil }
        if box! == CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)) {
            let bg = estimateBackground(buf, w, h)
            let tol = Int32(options.tolerance)
            box = scanBBox(buf, w, h) { px in
                abs(Int32(px[0]) - Int32(bg.0)) > tol ||
                abs(Int32(px[1]) - Int32(bg.1)) > tol ||
                abs(Int32(px[2]) - Int32(bg.2)) > tol
            }
            if box == nil { return nil }
        }

        // アンチエイリアスの端が欠けないよう 1px 外に広げる
        let left = max(0, box!.minX - 1), top = max(0, box!.minY - 1)
        let right = min(CGFloat(w), box!.maxX + 1), bottom = min(CGFloat(h), box!.maxY + 1)

        let s = 1.0 / scale
        let m = options.margin
        let x0 = max(bounds.minX, bounds.minX + left * s - m)
        let x1 = min(bounds.maxX, bounds.minX + right * s + m)
        // 走査は上が原点、PDF は下が原点
        let y1 = min(bounds.maxY, bounds.maxY - top * s + m)
        let y0 = max(bounds.minY, bounds.maxY - bottom * s - m)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 条件に合う画素の外接矩形を画素座標（左上が原点）で返す
    private static func scanBBox(_ buf: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int,
                                 _ hit: (UnsafeMutablePointer<UInt8>) -> Bool) -> CGRect? {
        var minX = w, minY = -1, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = buf + y * w * 4
            var first = -1, last = -1
            for x in 0..<w where hit(row + x * 4) {
                if first < 0 { first = x }
                last = x
            }
            if first < 0 { continue }
            if minY < 0 { minY = y }
            maxY = y
            if first < minX { minX = first }
            if last > maxX { maxX = last }
        }
        guard minY >= 0 else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    /// 四隅の多数決で背景色を決める
    private static func estimateBackground(_ buf: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int)
        -> (UInt8, UInt8, UInt8) {
        let idx = [0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + (w - 1)) * 4]
        let corners = idx.map { (buf[$0], buf[$0 + 1], buf[$0 + 2]) }
        var best = corners[0], bestCount = 0
        for c in corners {
            let n = corners.filter { $0 == c }.count
            if n > bestCount { best = c; bestCount = n }
        }
        return best
    }

    /// PDF データを受け取り、各ページを切り抜いた PDF データを返す
    static func trim(data: Data, options: TrimOptions) -> Data? {
        guard let doc = PDFDocument(data: data) else { return nil }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let rect = cropRect(for: page, options: options)
            else { continue }
            page.setBounds(rect, for: .mediaBox)
            page.setBounds(rect, for: .cropBox)
        }
        // そのまま書き出すと元のページ定義が残り、読み手によっては切り抜き前の
        // 矩形を拾ってしまうことがあるので、新しい書類に移し替えてから書き出す
        let out = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(page, at: out.pageCount)
        }
        return out.dataRepresentation()
    }
}

let CGColorSpaceDeviceRGB = CGColorSpaceCreateDeviceRGB()

// ---------------------------------------------------------------- 背景

enum Background: Int {
    case transparent = 0
    case white = 1
}

enum Backing {
    /// 各ページの下に白を敷く。元が透明な図を白地の PDF にしたいときに使う。
    /// 逆（白く塗られた図を透明にする）はできない。塗りを消すことになるため。
    static func fillWhite(data: Data) -> Data? {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out) else { return nil }
        var initial = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initial, nil) else { return nil }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
            ctx.beginPage(mediaBox: &box)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(box)
            page.draw(with: .cropBox, to: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }
}

/// ファイルを PDF データとして読む（.key は Keynote に書き出させる）
func readSource(_ url: URL) -> Outcome {
    switch url.pathExtension.lowercased() {
    case "key":
        return KeynoteFile.pdf(from: url)
    case "pdf":
        guard let d = try? Data(contentsOf: url) else { return .failed("読めません") }
        return .ok(d)
    default:
        guard let img = NSImage(contentsOf: url), let d = Clipboard.pdfData(from: img) else {
            return .failed("対応していない形式です")
        }
        return .ok(d)
    }
}

/// ペーストされた PDF に、トリミングと背景の設定を適用する
func process(_ source: Data, trim: Bool, background: Background, options: TrimOptions) -> Data {
    var out = source
    if trim, let trimmed = Trim.trim(data: out, options: options) { out = trimmed }
    if background == .white, let filled = Backing.fillWhite(data: out) { out = filled }
    return out
}

// ---------------------------------------------------------------- クリップボード

enum Clipboard {
    /// クリップボードの中身を PDF データとして取り出す。
    /// ベクタ（com.adobe.pdf）を最優先し、なければ画像を PDF に包む。
    static func readPDF() -> (data: Data, kind: String)? {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: NSPasteboard.PasteboardType("com.adobe.pdf")), !d.isEmpty {
            return (d, "ベクタ PDF")
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            if url.pathExtension.lowercased() == "pdf", let d = try? Data(contentsOf: url) {
                return (d, "PDF ファイル")
            }
            if let img = NSImage(contentsOf: url), let d = pdfData(from: img) {
                return (d, "画像ファイル")
            }
        }
        // PNG を先に見る（Keynote の TIFF は無圧縮で10MB を超えることがある）
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType.tiff] {
            if let d = pb.data(forType: type), let img = NSImage(data: d),
               let pdf = pdfData(from: img) {
                return (pdf, "画像（\(type.rawValue)）")
            }
        }
        return nil
    }

    static func pdfData(from image: NSImage) -> Data? {
        guard let page = PDFPage(image: image) else { return nil }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()
    }
}


// ---------------------------------------------------------------- Keynote 経由でベクタ化

// Keynote はクリップボードに PDF を載せない（PNG/TIFF と iWork 独自形式だけ）。
// そのため、ベクタで取り出すには一時書類に貼り戻して PDF へ書き出すしかない。
// 貼り付けは ⌘V を送るほかなく、アクセシビリティの許可が要る。
/// 取り出しの結果。失敗時は画面に出す理由を持つ
enum Outcome {
    case ok(Data)
    case failed(String)
}

enum Keynote {
    static let nativeType = NSPasteboard.PasteboardType("com.apple.iWork.TSPNativeData")

    static func clipboardHasObjects() -> Bool {
        NSPasteboard.general.types?.contains(nativeType) ?? false
    }

    /// 貼り付けは ⌘V を送るしかないため、アクセシビリティの許可が要る。
    /// 未許可なら OS の案内ダイアログを出す（そこから設定を開ける）。
    static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private static let script = """
    on run argv
    	set dst to item 1 of argv
    	if application "Keynote" is not running then
    		do shell script "open -g -a Keynote"
    	end if
    	-- 起動直後はイベントを受け取れないので、応答するまで待つ
    	repeat 150 times
    		try
    			tell application "Keynote" to count documents
    			exit repeat
    		on error
    			delay 0.2
    		end try
    	end repeat
    	tell application "Keynote"
    		activate
    		set doc to make new document
    		set width of doc to 2800
    		set height of doc to 2800
    		tell slide 1 of doc
    			set title showing to false
    			set body showing to false
    		end tell
    	end tell
    	delay 0.8
    	-- キー操作（⌘V）は送信そのものが拒まれることがあるので、まずメニュー項目を押す
    	tell application "System Events" to tell process "Keynote"
    		set pasted to false
    		repeat with nm in {"ペースト", "Paste"}
    			try
    				click menu item nm of menu 1 of (first menu bar item of menu bar 1 whose name is in {"編集", "Edit"})
    				set pasted to true
    				exit repeat
    			end try
    		end repeat
    		if not pasted then keystroke "v" using command down
    	end tell
    	set n to 0
    	repeat 50 times
    		delay 0.2
    		tell application "Keynote" to set n to count of (every iWork item of slide 1 of front document)
    		if n > 0 then exit repeat
    	end repeat
    	tell application "Keynote"
    		set doc to front document
    		if n is 0 then
    			close doc saving no
    			error "クリップボードの内容を Keynote に貼り付けられませんでした"
    		end if
    		export doc to POSIX file dst as PDF with properties {export style:IndividualSlides, all stages:false, skipped slides:false, PDF image quality:Best}
    		close doc saving no
    	end tell
    	return n as string
    end run
    """

    /// クリップボードの Keynote オブジェクトを、一時書類に貼り直して PDF として取り出す
    static func vectorPDF() -> Outcome {
        // 未許可なら OS の案内を出す。許可済みの判定が古いこともあるので、ここでは止めない
        _ = ensureAccessibility()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip2pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dst) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-", dst.path]
        let input = Pipe(), errors = Pipe()
        task.standardInput = input
        task.standardError = errors
        task.standardOutput = Pipe()
        do { try task.run() } catch { return .failed("osascript を起動できません") }
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0, let data = try? Data(contentsOf: dst), !data.isEmpty else {
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-1719") || msg.contains("(1002)") || msg.contains("-1728")
                || msg.lowercased().contains("assistive") {
                return .failed("アクセシビリティの許可が必要です"
                    + "（システム設定 > プライバシーとセキュリティ > アクセシビリティ で clip2pdf を許可してください）")
            }
            if msg.contains("-1743") {
                return .failed("Keynote を操作する許可が必要です"
                    + "（システム設定 > プライバシーとセキュリティ > オートメーション）")
            }
            return .failed("Keynote 経由の取り出しに失敗しました: \(msg)")
        }
        return .ok(data)
    }
}


// ---------------------------------------------------------------- Keynote ファイルの書き出し

// .key を Keynote に PDF として書き出させる（CLI の key2pdf と同じ経路）。
// クリップボード経由と違いキー操作は不要で、オートメーションの許可だけで動く。
enum KeynoteFile {
    private static let script = """
    on run argv
    \tset srcPath to item 1 of argv
    \tset dstPath to item 2 of argv
    \tif application "Keynote" is not running then
    \t\tdo shell script "open -g -a Keynote"
    \tend if
    \trepeat 150 times
    \t\ttry
    \t\t\ttell application "Keynote" to count documents
    \t\t\texit repeat
    \t\ton error
    \t\t\tdelay 0.2
    \t\tend try
    \tend repeat
    \ttell application "Keynote"
    \t\tset theDoc to missing value
    \t\tset wasOpen to false
    \t\trepeat with d in documents
    \t\t\ttry
    \t\t\t\tif (POSIX path of (file of d)) is srcPath then
    \t\t\t\t\tset theDoc to d
    \t\t\t\t\tset wasOpen to true
    \t\t\t\t\texit repeat
    \t\t\t\tend if
    \t\t\tend try
    \t\tend repeat
    \t\tif theDoc is missing value then
    \t\t\tset theDoc to open (POSIX file srcPath as alias)
    \t\tend if
    \t\texport theDoc to POSIX file dstPath as PDF with properties {export style:IndividualSlides, all stages:false, skipped slides:false, PDF image quality:Best}
    \t\t-- 開いていた書類は閉じない（作業中かもしれないため）
    \t\tif not wasOpen then close theDoc saving no
    \tend tell
    \treturn "ok"
    end run
    """

    static func pdf(from url: URL) -> Outcome {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip2pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dst) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-", url.path, dst.path]
        let input = Pipe(), errors = Pipe()
        task.standardInput = input
        task.standardError = errors
        task.standardOutput = Pipe()
        do { try task.run() } catch { return .failed("osascript を起動できません") }
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0, let data = try? Data(contentsOf: dst), !data.isEmpty else {
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-1743") {
                return .failed("Keynote を操作する許可が必要です"
                    + "（システム設定 > プライバシーとセキュリティ > オートメーション）")
            }
            return .failed("Keynote での書き出しに失敗しました: \(msg)")
        }
        return .ok(data)
    }
}

// ---------------------------------------------------------------- 保存

enum Pages {
    /// 1ページだけ取り出した PDF データを作る
    static func single(_ doc: PDFDocument, at index: Int) -> Data? {
        guard let page = doc.page(at: index)?.copy() as? PDFPage else { return nil }
        let out = PDFDocument()
        out.insert(page, at: 0)
        return out.dataRepresentation()
    }
}

enum Saver {
    /// <接頭辞>-01.pdf のように空いている連番を探して保存し、保存先を返す
    static func save(_ data: Data, to dir: URL, prefix: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = prefix.isEmpty ? "fig" : prefix
        for n in 1...9999 {
            let url = dir.appendingPathComponent(String(format: "%@-%02d.pdf", name, n))
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
                return url
            }
        }
        throw NSError(domain: "clip2pdf", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "空いているファイル名が見つかりません"])
    }
}

// ---------------------------------------------------------------- ドロップを受けるプレビュー

/// プレビュー表示（市松模様＋画像＋案内文）。ドロップの受け口は DropContainer 側。
final class DropView: NSView {
    var showsCheckerboard = false { didSet { needsDisplay = true } }
    var highlighted = false { didSet { updateColors() } }
    let imageView = NSImageView()
    let placeholder = NSTextField(labelWithString:
        "ここに ⌘V でペースト\nKeynote ファイルや PDF をドロップしても可")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleProportionallyUpOrDown
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 2
        placeholder.textColor = .secondaryLabelColor
        for v in [imageView, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // NSImageView は既定で PDF や画像のドラッグを受け付ける destination になっていて、
        // プレビュー全面を覆うためドロップを横取りして拒否してしまう。外しておく。
        imageView.unregisterDraggedTypes()
        placeholder.unregisterDraggedTypes()
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { updateColors() }

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        guard showsCheckerboard else { return }
        let side: CGFloat = 8
        NSColor(white: 0.90, alpha: 1).setFill()
        var y: CGFloat = 0, row = 0
        while y < bounds.height {
            var x: CGFloat = (row % 2 == 0) ? 0 : side
            while x < bounds.width {
                NSBezierPath(rect: NSRect(x: x, y: y, width: side, height: side)
                    .intersection(bounds.insetBy(dx: 1, dy: 1))).fill()
                x += side * 2
            }
            y += side
            row += 1
        }
    }

    private func updateColors() {
        layer?.borderWidth = highlighted ? 2 : 1
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func show(_ image: NSImage?) {
        imageView.image = image
        placeholder.isHidden = (image != nil)
    }

}

/// ウィンドウ全面でドロップを受ける入れ物。プレビューの外に落としても効くようにする。
final class DropContainer: NSView {
    var onFiles: (([URL]) -> Void)?
    var onPasteboard: (() -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.adobe.pdf"),
                                 .tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: opts) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        // ファイルが落ちてきたらファイルとして開く（.key / .pdf / 画像）
        let files = urls(from: sender)
        if !files.isEmpty {
            onFiles?(files)
            return true
        }
        // それ以外は一度クリップボードに移してから、ペーストと同じ経路で扱う
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(sender.draggingPasteboard.pasteboardItems ?? [])
        onPasteboard?()
        return true
    }
}

// ---------------------------------------------------------------- 画面

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let drop = DropView(frame: .zero)
    private let trimCheck = NSButton(checkboxWithTitle: "余白をトリミング", target: nil, action: nil)
    private let backgroundControl = NSSegmentedControl(labels: ["透明", "白"],
                                                       trackingMode: .selectOne,
                                                       target: nil, action: nil)
    private let extractControl = NSSegmentedControl(labels: ["ベクタ（Keynote 経由）", "画像"],
                                                    trackingMode: .selectOne,
                                                    target: nil, action: nil)
    private let autoSaveCheck = NSButton(checkboxWithTitle: "ペーストしたら自動で保存",
                                         target: nil, action: nil)
    private let marginField = NSTextField(string: "0")
    private let toleranceField = NSTextField(string: "8")
    private let prefixField = NSTextField(string: "fig")
    private let dirLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Keynote で図をコピーして、⌘V でペーストしてください")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let settingsButton = NSButton(title: "設定を開く", target: nil, action: nil)
    private let splitCheck = NSButton(checkboxWithTitle: "ページごとに別ファイル",
                                      target: nil, action: nil)
    private let besideCheck = NSButton(checkboxWithTitle: "元ファイルの隣に保存",
                                       target: nil, action: nil)
    private let prevButton = NSButton(title: "◀", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")

    private var current: Data?          // 切り抜き後（保存されるもの）
    private var original: Data?         // ペーストされたそのまま
    private var usedKeynote = false     // Keynote 経由で取り出したか（地色が入っている）
    private var sourceName: String?     // ファイル由来ならその名前（出力名に使う）
    private var sourceDir: URL?         // ファイル由来ならその置き場所
    private var pageIndex = 0
    private var saveDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ note: Notification) {
        if let path = defaults.string(forKey: "saveDir") {
            saveDir = URL(fileURLWithPath: path)
        }
        prefixField.stringValue = defaults.string(forKey: "prefix") ?? "fig"
        marginField.stringValue = defaults.string(forKey: "margin") ?? "0"
        toleranceField.stringValue = defaults.string(forKey: "tolerance") ?? "8"
        trimCheck.state = (defaults.object(forKey: "trim") as? Bool ?? true) ? .on : .off
        backgroundControl.selectedSegment = defaults.integer(forKey: "background")
        extractControl.selectedSegment = defaults.integer(forKey: "extract")
        autoSaveCheck.state = (defaults.bool(forKey: "autoSave")) ? .on : .off
        splitCheck.state = (defaults.object(forKey: "split") as? Bool ?? true) ? .on : .off
        besideCheck.state = (defaults.object(forKey: "beside") as? Bool ?? true) ? .on : .off

        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // Dock アイコンへのドロップや「このアプリケーションで開く」、open コマンドから。
    // 新旧どちらの入口も受ける（環境によって呼ばれるものが違う）
    func application(_ application: NSApplication, open urls: [URL]) {
        openFiles(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: 組み立て

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "clip2pdf について", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "clip2pdf を終了", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "開く…", action: #selector(openPanel), keyEquivalent: "o")
            .target = self
        editMenu.addItem(withTitle: "ペースト", action: #selector(paste), keyEquivalent: "v")
            .target = self
        editMenu.addItem(withTitle: "保存", action: #selector(saveCurrent), keyEquivalent: "s")
            .target = self
        editItem.submenu = editMenu
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        let row: ([NSView]) -> NSStackView = { views in
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        for f in [marginField, toleranceField] {
            f.formatter = nil
            f.widthAnchor.constraint(equalToConstant: 56).isActive = true
            f.alignment = .right
        }
        prefixField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 260).isActive = true

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openAccessibilitySettings)
        settingsButton.isHidden = true
        saveButton.target = self
        saveButton.action = #selector(saveCurrent)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        for c in [trimCheck, autoSaveCheck, splitCheck, besideCheck] {
            c.target = self
            c.action = #selector(optionChanged)
        }
        prevButton.target = self; prevButton.action = #selector(showPrevPage)
        nextButton.target = self; nextButton.action = #selector(showNextPage)
        for c in [backgroundControl, extractControl] {
            c.target = self
            c.action = #selector(optionChanged)
        }
        for f in [marginField, toleranceField, prefixField] { f.target = self; f.action = #selector(optionChanged) }
        let chooseButton = NSButton(title: "変更…", target: self, action: #selector(chooseDir))
        updateDirLabel()

        let stack = NSStackView(views: [
            drop,
            row([trimCheck, NSTextField(labelWithString: "余白"), marginField,
                 NSTextField(labelWithString: "pt   しきい値"), toleranceField, NSView()]),
            row([NSTextField(labelWithString: "取り出し:"), extractControl, NSView()]),
            row([NSTextField(labelWithString: "背景:"), backgroundControl, NSView()]),
            row([prevButton, pageLabel, nextButton, NSView(), splitCheck]),
            row([NSTextField(labelWithString: "保存先:"), dirLabel, chooseButton, besideCheck, NSView()]),
            row([NSTextField(labelWithString: "名前:"), prefixField, autoSaveCheck, NSView(), saveButton]),
            row([statusLabel, settingsButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "clip2pdf"
        window.delegate = self
        let container = DropContainer()
        container.onFiles = { [weak self] urls in self?.openFiles(urls) }
        container.onPasteboard = { [weak self] in self?.paste() }
        container.onHighlight = { [weak self] on in self?.drop.highlighted = on }
        window.contentView = container
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
    }


    /// ドロップの受け口が正しく登録されているかを返す（--selftest-drop 用）。
    /// NSImageView のように既定でドラッグを受ける部品が前面にあると、
    /// ウィンドウに落としても無反応になるため、ここで検査しておく。
    func dropDiagnostics() -> (ok: Bool, text: String) {
        let container = window.contentView?.registeredDraggedTypes.map { $0.rawValue } ?? []
        let onPreview = drop.registeredDraggedTypes.count
        let onImage = drop.imageView.registeredDraggedTypes.count
        let acceptsFiles = container.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
        let text = "ウィンドウが受ける型: \(container.count) 件"
            + "（ファイル: \(acceptsFiles ? "あり" : "なし")）"
            + " / 前面の部品が横取りする型: プレビュー \(onPreview) 件・画像 \(onImage) 件"
        return (acceptsFiles && onPreview == 0 && onImage == 0, text)
    }

    // MARK: ファイルを開く

    @objc private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["key", "pdf", "png", "jpg", "jpeg", "tiff", "heic"]
        if panel.runModal() == .OK { openFiles(panel.urls) }
    }

    /// ドロップされた（または開かれた）ファイルを順に変換して保存する。
    /// ファイルを渡す操作は「変換してほしい」という意味なので、確認を待たずに保存する。
    func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        status(urls.count == 1 ? "\(urls[0].lastPathComponent) を処理しています…"
                               : "\(urls.count) 件を処理しています…")
        saveButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            var saved: [URL] = []
            var failures: [String] = []
            for url in urls {
                let outcome = readSource(url)
                let isKey = url.pathExtension.lowercased() == "key"
                // 画面の状態を触るので、1件ずつメインスレッドで処理する
                DispatchQueue.main.sync {
                    switch outcome {
                    case .ok(let data):
                        self.load(data, name: url.deletingPathExtension().lastPathComponent,
                                  dir: url.deletingLastPathComponent(),
                                  note: isKey ? "Keynote から書き出し" : nil, keynote: isKey)
                        saved.append(contentsOf: self.saveAll(quiet: true, returning: true))
                    case .failed(let why):
                        failures.append("\(url.lastPathComponent): \(why)")
                    }
                }
            }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if !failures.isEmpty {
                    self.status(failures.joined(separator: " / "), warn: true)
                } else if saved.count == 1 {
                    self.status("保存しました: \(saved[0].path)")
                } else {
                    self.status("\(saved.count) 個の PDF を保存しました"
                                + "（\(saved.first?.deletingLastPathComponent().path ?? "")）")
                }
            }
        }
    }

    /// 取り込んだ PDF を保持して、設定を適用した結果を画面に出す
    private func load(_ data: Data, name: String?, dir: URL?, note: String?, keynote: Bool) {
        original = data
        sourceName = name
        sourceDir = dir
        usedKeynote = keynote
        pageIndex = 0
        apply(note: note)
    }

    // MARK: ページ送り

    @objc private func showPrevPage() { pageIndex -= 1; refreshPreview() }
    @objc private func showNextPage() { pageIndex += 1; refreshPreview() }

    private func refreshPreview() {
        guard let data = current, let doc = PDFDocument(data: data) else { return }
        pageIndex = max(0, min(pageIndex, doc.pageCount - 1))
        if let page = doc.page(at: pageIndex) { drop.show(thumbnail(of: page)) }
        updatePageControls(doc.pageCount)
    }

    private func updatePageControls(_ count: Int) {
        let many = count > 1
        prevButton.isHidden = !many
        nextButton.isHidden = !many
        pageLabel.isHidden = !many
        splitCheck.isHidden = !many
        pageLabel.stringValue = many ? "\(pageIndex + 1) / \(count) ページ" : ""
        prevButton.isEnabled = pageIndex > 0
        nextButton.isEnabled = pageIndex < count - 1
    }

    // MARK: 保存先と名前

    private func destinationDir() -> URL {
        if besideCheck.state == .on, let dir = sourceDir { return dir }
        return saveDir
    }

    private func effectivePrefix() -> String {
        if let n = sourceName, !n.isEmpty { return n }
        return prefixField.stringValue
    }

    // MARK: 操作

    private var options: TrimOptions {
        TrimOptions(margin: CGFloat(Double(marginField.stringValue) ?? 0),
                    dpi: 150,
                    tolerance: Int(toleranceField.stringValue) ?? 8)
    }

    @objc private func paste() {
        // Keynote はクリップボードに PDF を載せないので、ベクタが要るときは貼り戻して書き出す
        guard Keynote.clipboardHasObjects(), extractControl.selectedSegment == 0 else {
            pasteFromClipboard()
            return
        }
        status("Keynote 経由でベクタにしています…")
        saveButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Keynote.vectorPDF()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                switch outcome {
                case .ok(let data):
                    self.load(data, name: nil, dir: nil, note: "Keynote 経由・ベクタ", keynote: true)
                    if self.autoSaveCheck.state == .on { self.saveCurrent() }
                case .failed(let why):
                    self.pasteFromClipboard()
                    self.status("\(why)｜画像として取り込みました", warn: true)
                }
            }
        }
    }

    private func pasteFromClipboard() {
        guard let (data, kind) = Clipboard.readPDF() else {
            status("クリップボードに図がありません（Keynote で図を選んで ⌘C してください）", warn: true)
            return
        }
        load(data, name: nil, dir: nil, note: kind, keynote: false)
        if autoSaveCheck.state == .on { saveCurrent() }
    }

    @objc private func optionChanged() {
        persist()
        if original != nil { apply(note: nil) }
    }

    /// トリミング設定を今のデータに適用し、プレビューと状態表示を更新する
    private var background: Background {
        Background(rawValue: backgroundControl.selectedSegment) ?? .transparent
    }

    private func apply(note: String?) {
        guard let src = original else { return }
        // Keynote 経由の PDF はテーマの地色が入っているので、背景の指定は効かせない
        backgroundControl.isEnabled = !usedKeynote
        let out = process(src, trim: trimCheck.state == .on,
                          background: usedKeynote ? .transparent : background, options: options)
        current = out
        saveButton.isEnabled = true

        guard let doc = PDFDocument(data: out), doc.pageCount > 0 else { return }
        pageIndex = max(0, min(pageIndex, doc.pageCount - 1))
        guard let page = doc.page(at: pageIndex) else { return }
        updatePageControls(doc.pageCount)
        let b = page.bounds(for: .cropBox)
        // 透明のときは市松模様を敷いて、白地でないことが見て分かるようにする
        drop.showsCheckerboard = (background == .transparent && !usedKeynote)
        drop.show(thumbnail(of: page))
        let before = PDFDocument(data: src)?.page(at: pageIndex)?.bounds(for: .cropBox) ?? b
        let kind = note.map { "\($0)・" } ?? (usedKeynote ? "Keynote 経由・ベクタ・" : "")
        if trimCheck.state == .on {
            status(String(format: "%@%.1f×%.1fpt → %.1f×%.1fpt（%dページ）",
                          kind, before.width, before.height, b.width, b.height, doc.pageCount))
        } else {
            status(String(format: "%@%.1f×%.1fpt（%dページ）", kind, b.width, b.height, doc.pageCount))
        }
    }

    private func thumbnail(of page: PDFPage) -> NSImage {
        let b = page.bounds(for: .cropBox)
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(b.width, b.height))
        let size = NSSize(width: max(1, b.width * scale), height: max(1, b.height * scale))
        return page.thumbnail(of: size, for: .cropBox)
    }

    @objc private func saveCurrent() { _ = saveAll(quiet: false) }

    /// 保存して、書き出したファイルを返す。複数ページは設定に応じて1枚ずつに分ける。
    @discardableResult
    private func saveAll(quiet: Bool, returning: Bool = false) -> [URL] {
        guard let data = current, let doc = PDFDocument(data: data), doc.pageCount > 0 else { return [] }
        let dir = destinationDir()
        let prefix = effectivePrefix()
        var saved: [URL] = []
        do {
            if splitCheck.state == .on && doc.pageCount > 1 {
                for i in 0..<doc.pageCount {
                    guard let one = Pages.single(doc, at: i) else { continue }
                    saved.append(try Saver.save(one, to: dir, prefix: prefix))
                }
            } else {
                saved.append(try Saver.save(data, to: dir, prefix: prefix))
            }
        } catch {
            if !quiet { status("保存に失敗しました: \(error.localizedDescription)", warn: true) }
            return saved
        }
        if !quiet {
            status(saved.count == 1
                   ? "保存しました: \(saved[0].path)"
                   : "\(saved.count) 個の PDF を保存しました（\(dir.path)）")
        }
        return saved
    }

    @objc private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = saveDir
        panel.prompt = "ここに保存"
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url
            updateDirLabel()
            persist()
        }
    }

    private func updateDirLabel() {
        dirLabel.stringValue = saveDir.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func persist() {
        defaults.set(saveDir.path, forKey: "saveDir")
        defaults.set(prefixField.stringValue, forKey: "prefix")
        defaults.set(marginField.stringValue, forKey: "margin")
        defaults.set(toleranceField.stringValue, forKey: "tolerance")
        defaults.set(trimCheck.state == .on, forKey: "trim")
        defaults.set(backgroundControl.selectedSegment, forKey: "background")
        defaults.set(extractControl.selectedSegment, forKey: "extract")
        defaults.set(splitCheck.state == .on, forKey: "split")
        defaults.set(besideCheck.state == .on, forKey: "beside")
        defaults.set(autoSaveCheck.state == .on, forKey: "autoSave")
    }

    private func status(_ text: String, warn: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = warn ? .systemRed : .secondaryLabelColor
        settingsButton.isHidden = !text.contains("アクセシビリティ")
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// ---------------------------------------------------------------- 起動

// GUI を出さずに動かすモード。CLI 版と結果を突き合わせるテストに使う。
//   --trim <入力.pdf> <出力.pdf>   ファイルを切り抜く
//   --convert <入力> <出力ディレクトリ>  .key / PDF / 画像をページごとに書き出す
//   --clipboard <出力.pdf>         クリップボードの図を取り出して切り抜く
// どちらも [--margin N] [--dpi N] [--tolerance N] [--no-trim]
// [--background transparent|white] を受け付ける。
//   --clipboard に --keynote を足すと、Keynote に貼り戻してベクタで取り出す。
func runHeadless(_ args: [String]) -> Int32 {
    func err(_ msg: String) -> Int32 {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        return 1
    }
    func value(_ name: String, _ fallback: Double) -> Double {
        guard let j = args.firstIndex(of: name), args.count > j + 1 else { return fallback }
        return Double(args[j + 1]) ?? fallback
    }
    let opts = TrimOptions(margin: CGFloat(value("--margin", 0)),
                           dpi: CGFloat(value("--dpi", 150)),
                           tolerance: Int(value("--tolerance", 8)))

    let background: Background = args.contains("--background") &&
        args[(args.firstIndex(of: "--background") ?? 0) + 1] == "white" ? .white : .transparent
    let trim = !args.contains("--no-trim")

    // --convert: .key / PDF / 画像を読んで、ページごとに出力ディレクトリへ保存する
    if let i = args.firstIndex(of: "--convert") {
        guard args.count > i + 2 else {
            return err("使い方: clip2pdf --convert <入力.key|入力.pdf> <出力ディレクトリ>")
        }
        let src = URL(fileURLWithPath: args[i + 1])
        let outDir = URL(fileURLWithPath: args[i + 2])
        var data: Data
        switch readSource(src) {
        case .ok(let d): data = d
        case .failed(let why): return err(why)
        }
        data = process(data, trim: trim, background: background, options: opts)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return err("PDF を読めません") }
        let prefix = src.deletingPathExtension().lastPathComponent
        var saved = 0
        do {
            if args.contains("--merge") || doc.pageCount == 1 {
                print(try Saver.save(data, to: outDir, prefix: prefix).path)
                saved = 1
            } else {
                for n in 0..<doc.pageCount {
                    guard let one = Pages.single(doc, at: n) else { continue }
                    print(try Saver.save(one, to: outDir, prefix: prefix).path)
                    saved += 1
                }
            }
        } catch {
            return err("保存できません: \(error.localizedDescription)")
        }
        FileHandle.standardError.write(Data("\(saved) 個保存しました\n".utf8))
        return 0
    }

    var source: Data
    var output: String
    if let i = args.firstIndex(of: "--trim") {
        guard args.count > i + 2 else { return err("使い方: clip2pdf --trim <入力.pdf> <出力.pdf>") }
        guard let d = FileManager.default.contents(atPath: args[i + 1]) else {
            return err("入力を読めません: \(args[i + 1])")
        }
        source = d
        output = args[i + 2]
    } else if let i = args.firstIndex(of: "--clipboard") {
        guard args.count > i + 1 else { return err("使い方: clip2pdf --clipboard <出力.pdf>") }
        if args.contains("--keynote") {
            switch Keynote.vectorPDF() {
            case .ok(let d):
                FileHandle.standardError.write(Data("クリップボード: Keynote 経由・ベクタ\n".utf8))
                source = d
            case .failed(let why):
                return err(why)
            }
        } else {
            guard let (d, kind) = Clipboard.readPDF() else {
                return err("クリップボードに図がありません")
            }
            FileHandle.standardError.write(Data("クリップボード: \(kind)\n".utf8))
            source = d
        }
        output = args[i + 1]
    } else {
        return err("使い方: clip2pdf [--trim <入力.pdf> | --clipboard] <出力.pdf>")
    }

    let result = process(source, trim: trim, background: background, options: opts)
    do { try result.write(to: URL(fileURLWithPath: output)) } catch {
        return err("書き出せません: \(error.localizedDescription)")
    }
    return 0
}

let args = CommandLine.arguments

// 画面を作ってドロップの受け口だけ検査する（回帰防止）
if args.contains("--selftest-drop") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let controller = Controller()
    app.delegate = controller
    controller.applicationDidFinishLaunching(Notification(name: Notification.Name("selftest")))
    let result = controller.dropDiagnostics()
    print(result.text)
    exit(result.ok ? 0 : 1)
}

if args.contains("--trim") || args.contains("--clipboard") || args.contains("--convert") {
    exit(runHeadless(args))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
app.delegate = controller
app.run()
