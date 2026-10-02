#!/usr/bin/env swift
//
// 生成 App 图标：Resources/AppIcon.icns + docs/logo.png
//
//   swift tools/make-icon.swift
//
// 图标就是 App 本身的缩影：一块深色「屏幕」，右边缘挂着一个带反角的把手，
// 左边三颗状态点（执行中 / 待确认 / 空闲），用的是 App 里同一套颜色。
// 设计基准 1024×1024，等比缩放到各尺寸；改完重跑本脚本即可。
//
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent } ?? ".")
    .deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let docs = root.appendingPathComponent("docs")

// MARK: 颜色（与 Sources/Models.swift 里的 TaskState.color 对齐）
let cRunning = CGColor(red: 0.16, green: 0.56, blue: 1.00, alpha: 1)
let cConfirm = CGColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1)
let cIdle    = CGColor(red: 0.20, green: 0.80, blue: 0.36, alpha: 1)

/// 右侧贴边、左圆角、右侧带反角的把手——和 App 里 DockShape 同一套几何
func handlePath(_ rect: CGRect, corner: CGFloat, notch: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let r = min(corner, rect.height / 2, rect.width / 2)
    let nr = min(notch, rect.width / 3, rect.height / 3)

    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - nr, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY - nr),
                   control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + nr))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - nr, y: rect.maxY),
                   control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                   control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                   control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    return p
}

func makeIcon(px: Int) -> CGImage? {
    let size = CGFloat(px)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // 换成「1024 设计坐标系、y 向下」再画，省得反复换算
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: size / 1024.0, y: -size / 1024.0)

    // ---- 底：深色 squircle（相当于「屏幕」）----
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 195, cornerHeight: 195, transform: nil))
    ctx.clip()
    if let g = CGGradient(colorsSpace: space,
                          colors: [CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1),
                                   CGColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1)] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 100),
                               end: CGPoint(x: 512, y: 924), options: [])
    }
    ctx.restoreGState()

    // ---- 左：三颗状态点（执行中 / 待确认 / 空闲）----
    // x 取「squircle 左边缘」到「把手左边缘」的中点，视觉上才不偏
    let dots: [(y: CGFloat, c: CGColor)] = [(404, cRunning), (512, cConfirm), (620, cIdle)]
    for d in dots {
        ctx.setShadow(offset: .zero, blur: 40, color: d.c.copy(alpha: 0.9))
        ctx.setFillColor(d.c)
        ctx.fillEllipse(in: CGRect(x: 411, y: d.y - 52, width: 104, height: 104))
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // ---- 右：贴右边缘的把手（带反角）----
    let handle = CGRect(x: 826, y: 356, width: 98, height: 312)
    let path = handlePath(handle, corner: 44, notch: 34)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1))
    ctx.setShadow(offset: .zero, blur: 30,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    // 把手中间两道握把纹
    ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.8))
    for dy in [-18.0, 18.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 858, y: 512 + dy - 5, width: 30, height: 10),
                           cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
    }

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

// MARK: 输出

try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// iconset 需要的尺寸 → 文件名
let plan: [(px: Int, names: [String])] = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for step in plan {
    guard let img = makeIcon(px: step.px) else { continue }
    for name in step.names {
        try writePNG(img, to: tmp.appendingPathComponent(name))
    }
    if step.px == 512 {
        try writePNG(img, to: docs.appendingPathComponent("logo.png"))
    }
    print("  ✓ \(step.px)px")
}

// iconset → icns
let icns = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: tmp)

let size = (try? FileManager.default.attributesOfItem(atPath: icns.path)[.size] as? Int) ?? 0
print("已生成 \(icns.path)  (\(size) bytes)")
print("已生成 \(docs.appendingPathComponent("logo.png").path)")
