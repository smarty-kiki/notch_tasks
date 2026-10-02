#!/usr/bin/env swift
//
// 把若干张图横向拼成一张对比图，带标题。
//
//   swift tools/make-strip.swift <输出.png> <缩放> <标题>=<图片路径> [<标题>=<图片路径> ...]
//
// 例：
//   swift tools/make-strip.swift docs/把手三种形态.png 1.0 \
//     常态=/tmp/a.png 待确认=/tmp/b.png 刚完成=/tmp/c.png
//
// 只依赖 AppKit，不需要 GUI。用于生成 docs/ 里的对比图。
//
import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    FileHandle.standardError.write("""
    用法：make-strip.swift <输出.png> <缩放> <标题>=<图片路径> ...

    """.data(using: .utf8)!)
    exit(2)
}

let outPath = args[0]
let scale = CGFloat(Double(args[1]) ?? 1.0)
let items: [(label: String, image: NSImage)] = args.dropFirst(2).compactMap { spec in
    guard let eq = spec.firstIndex(of: "=") else { return nil }
    let label = String(spec[spec.startIndex..<eq])
    let path = String(spec[spec.index(after: eq)...])
    guard let img = NSImage(contentsOfFile: path) else {
        print("⚠️  读不到 \(path)")
        return nil
    }
    return (label, img)
}
guard !items.isEmpty else {
    FileHandle.standardError.write("没有任何可用的输入图\n".data(using: .utf8)!)
    exit(1)
}

let gap: CGFloat = 16
let pad: CGFloat = 28
let captionH: CGFloat = 34

let sizes = items.map { CGSize(width: $0.image.size.width * scale,
                              height: $0.image.size.height * scale) }
let W = pad * 2 + sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(items.count - 1)
let H = pad * 2 + captionH + (sizes.map(\.height).max() ?? 0)

// 画布按 2 倍像素渲染，输出才是 Retina 清晰度（W/H 仍是点）
let density: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int((W * density).rounded()),
                                 pixelsHigh: Int((H * density).rounded()),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("画布创建失败\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 深色底，和 App 的观感一致
NSColor(deviceWhite: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(deviceWhite: 0.82, alpha: 1),
]

var x = pad
for (i, item) in items.enumerated() {
    let s = sizes[i]
    // 顶对齐：各图高度不同时，顶部（形状的锚点边）要在同一条线上
    item.image.draw(in: NSRect(x: x, y: pad, width: s.width, height: s.height))
    item.label.draw(at: NSPoint(x: x + 2, y: H - pad - 20), withAttributes: attrs)
    x += s.width + gap
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)  (\(Int(W))×\(Int(H))pt @\(Int(density))x)")
