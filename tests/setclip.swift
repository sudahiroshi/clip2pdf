// テスト用: PDF ファイルをクリップボードに com.adobe.pdf として載せる。
// Keynote で図をコピーしたときと同じ形にする。
import AppKit
guard CommandLine.arguments.count > 1,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("使い方: setclip <file.pdf>\n".utf8))
    exit(2)
}
let pb = NSPasteboard.general
pb.clearContents()
pb.setData(data, forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
