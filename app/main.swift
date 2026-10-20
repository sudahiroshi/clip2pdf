// clip2pdf — クリップボードの図を PDF として保存するアプリ。
//
// Keynote で図をコピーすると、クリップボードにベクタの PDF（com.adobe.pdf）が載る。
// このアプリに切り替えて ⌘V すると、それを取り出して余白を落とし、PDF として保存する。
//
// 切り抜きは Quartz でページをラスタ化して「内容のある範囲」を求め、PDFKit で
// ページ矩形（MediaBox/CropBox）を付け替える方式。中身は再描画しないのでベクタのまま。
// CLI の key2pdf / pdftrim と同じ考え方・同じ結果になる。

import AppKit
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
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType.png] {
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

// ---------------------------------------------------------------- 保存

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

final class DropView: NSView {
    var onDrop: (() -> Void)?
    let imageView = NSImageView()
    let placeholder = NSTextField(labelWithString: "ここに ⌘V でペースト\n（図をドラッグ＆ドロップしても可）")

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
        registerForDraggedTypes([NSPasteboard.PasteboardType("com.adobe.pdf"), .tiff, .png, .fileURL])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { updateColors() }

    private func updateColors() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func show(_ image: NSImage?) {
        imageView.image = image
        placeholder.isHidden = (image != nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // ドロップされた内容を一度クリップボードに移してから、ペーストと同じ経路で扱う
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(sender.draggingPasteboard.pasteboardItems ?? [])
        onDrop?()
        return true
    }
}

// ---------------------------------------------------------------- 画面

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let drop = DropView(frame: .zero)
    private let trimCheck = NSButton(checkboxWithTitle: "余白をトリミング", target: nil, action: nil)
    private let autoSaveCheck = NSButton(checkboxWithTitle: "ペーストしたら自動で保存",
                                         target: nil, action: nil)
    private let marginField = NSTextField(string: "0")
    private let toleranceField = NSTextField(string: "8")
    private let prefixField = NSTextField(string: "fig")
    private let dirLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Keynote で図をコピーして、⌘V でペーストしてください")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private var current: Data?          // 切り抜き後（保存されるもの）
    private var original: Data?         // ペーストされたそのまま
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
        autoSaveCheck.state = (defaults.bool(forKey: "autoSave")) ? .on : .off

        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

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
        drop.onDrop = { [weak self] in self?.paste() }
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        saveButton.target = self
        saveButton.action = #selector(saveCurrent)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        for c in [trimCheck, autoSaveCheck] { c.target = self; c.action = #selector(optionChanged) }
        for f in [marginField, toleranceField, prefixField] { f.target = self; f.action = #selector(optionChanged) }
        let chooseButton = NSButton(title: "変更…", target: self, action: #selector(chooseDir))
        updateDirLabel()

        let stack = NSStackView(views: [
            drop,
            row([trimCheck, NSTextField(labelWithString: "余白"), marginField,
                 NSTextField(labelWithString: "pt   しきい値"), toleranceField, NSView()]),
            row([NSTextField(labelWithString: "保存先:"), dirLabel, chooseButton, NSView()]),
            row([NSTextField(labelWithString: "名前:"), prefixField, autoSaveCheck, NSView(), saveButton]),
            statusLabel,
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
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
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

    // MARK: 操作

    private var options: TrimOptions {
        TrimOptions(margin: CGFloat(Double(marginField.stringValue) ?? 0),
                    dpi: 150,
                    tolerance: Int(toleranceField.stringValue) ?? 8)
    }

    @objc private func paste() {
        guard let (data, kind) = Clipboard.readPDF() else {
            status("クリップボードに図がありません（Keynote で図を選んで ⌘C してください）", warn: true)
            return
        }
        original = data
        apply(note: kind)
        if autoSaveCheck.state == .on { saveCurrent() }
    }

    @objc private func optionChanged() {
        persist()
        if original != nil { apply(note: nil) }
    }

    /// トリミング設定を今のデータに適用し、プレビューと状態表示を更新する
    private func apply(note: String?) {
        guard let src = original else { return }
        var out = src
        if trimCheck.state == .on, let trimmed = Trim.trim(data: src, options: options) {
            out = trimmed
        }
        current = out
        saveButton.isEnabled = true

        guard let doc = PDFDocument(data: out), let page = doc.page(at: 0) else { return }
        let b = page.bounds(for: .cropBox)
        drop.show(thumbnail(of: page))
        let before = PDFDocument(data: src)?.page(at: 0)?.bounds(for: .cropBox) ?? b
        let kind = note.map { "\($0)・" } ?? ""
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

    @objc private func saveCurrent() {
        guard let data = current else { return }
        do {
            let url = try Saver.save(data, to: saveDir, prefix: prefixField.stringValue)
            status("保存しました: \(url.path)")
        } catch {
            status("保存に失敗しました: \(error.localizedDescription)", warn: true)
        }
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
        defaults.set(autoSaveCheck.state == .on, forKey: "autoSave")
    }

    private func status(_ text: String, warn: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = warn ? .systemRed : .secondaryLabelColor
    }
}

// ---------------------------------------------------------------- 起動

// GUI を出さずに動かすモード。CLI 版と結果を突き合わせるテストに使う。
//   --trim <入力.pdf> <出力.pdf>   ファイルを切り抜く
//   --clipboard <出力.pdf>         クリップボードの図を取り出して切り抜く
// どちらも [--margin N] [--dpi N] [--tolerance N] [--no-trim] を受け付ける。
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
        guard let (d, kind) = Clipboard.readPDF() else {
            return err("クリップボードに図がありません")
        }
        FileHandle.standardError.write(Data("クリップボード: \(kind)\n".utf8))
        source = d
        output = args[i + 1]
    } else {
        return err("使い方: clip2pdf [--trim <入力.pdf> | --clipboard] <出力.pdf>")
    }

    var result = source
    if !args.contains("--no-trim") {
        guard let out = Trim.trim(data: source, options: opts) else { return err("切り抜きに失敗しました") }
        result = out
    }
    do { try result.write(to: URL(fileURLWithPath: output)) } catch {
        return err("書き出せません: \(error.localizedDescription)")
    }
    return 0
}

let args = CommandLine.arguments
if args.contains("--trim") || args.contains("--clipboard") {
    exit(runHeadless(args))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
app.delegate = controller
app.run()
