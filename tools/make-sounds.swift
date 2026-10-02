//
// 生成 app 自带的一版提示音：把系统音效（/System/Library/Sounds）整体放大后
// 写进 Resources/Sounds/。
//
//   swift tools/make-sounds.swift      （或 make sounds）
//
// 跟 tools/make-icon.swift 一样是**可复现**的工具，改完重跑即可。
//
// 为什么要放大：系统音效录得偏轻 —— 实测峰值只有 -14 dBFS 上下，留了十几 dB 余量，
// 而 NSSound 的 volume 默认就是 1.0、上限也是 1.0（设 2.0 会被 clamp），
// 走播放器这条路一点提升空间都没有。所以直接在音频数据上放。
//
// 放大用的是**线性增益**（不是压缩、不是限幅），所以完全无损、没有失真。
// 三个音效共用同一个增益（按最响的那个定），相对响度关系保持不变。
//
// 播放端见 Sources/SoundPlayer.swift：优先用这份，找不到才退回系统原版。

import AVFoundation
import Foundation

let srcDir = "/System/Library/Sounds"
let outDir = "Resources/Sounds"
let names = ["Glass", "Ping", "Basso"]

/// 目标峰值：-1 dBFS，留 1 dB 余量，避免各种播放链路上的意外削波
let targetPeak: Float = 0.891

func dB(_ v: Double) -> Double { v <= 1e-9 ? -120 : 20 * log10(v) }

func load(_ name: String) -> AVAudioPCMBuffer? {
    let url = URL(fileURLWithPath: "\(srcDir)/\(name).aiff")
    guard let file = try? AVAudioFile(forReading: url) else {
        FileHandle.standardError.write("读不到 \(url.path)\n".data(using: .utf8)!)
        return nil
    }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
          (try? file.read(into: buf)) != nil else { return nil }
    return buf
}

func peak(of buf: AVAudioPCMBuffer) -> Float {
    guard let data = buf.floatChannelData else { return 0 }
    var m: Float = 0
    for c in 0..<Int(buf.format.channelCount) {
        let p = data[c]
        for i in 0..<Int(buf.frameLength) { m = max(m, abs(p[i])) }
    }
    return m
}

func rms(of buf: AVAudioPCMBuffer) -> Double {
    guard let data = buf.floatChannelData else { return 0 }
    var sumSq = 0.0, n = 0
    for c in 0..<Int(buf.format.channelCount) {
        let p = data[c]
        for i in 0..<Int(buf.frameLength) {
            let v = Double(p[i]); sumSq += v * v; n += 1
        }
    }
    return n > 0 ? (sumSq / Double(n)).squareRoot() : 0
}

/// 就地乘增益
func apply(_ gain: Float, to buf: AVAudioPCMBuffer) {
    guard let data = buf.floatChannelData else { return }
    for c in 0..<Int(buf.format.channelCount) {
        let p = data[c]
        for i in 0..<Int(buf.frameLength) { p[i] *= gain }
    }
}

// ---- 1. 全部读进来，先看看最响的是谁 ----
var loaded: [(name: String, buf: AVAudioPCMBuffer, before: Float, rmsBefore: Double)] = []
for n in names {
    guard let b = load(n) else { exit(1) }
    loaded.append((n, b, peak(of: b), rms(of: b)))
}

let loudest = loaded.map(\.before).max() ?? 1
guard loudest > 0 else { exit(1) }

// 统一增益：让最响的那个正好落在 targetPeak
let gain = targetPeak / loudest

// ---- 2. 写出 ----
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// 16-bit big-endian PCM（AIFF）。AVAudioFile 的 processingFormat 恒为
// float32 非交错，write(from:) 会自己编码成这里指定的位深 —— 不用手动转换。
func settings(_ rate: Double, _ channels: Int) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
}

print(String(format: "统一增益 %+.1f dB（线性 ×%.2f，无损）", dB(Double(gain)), gain))
print(String(repeating: "-", count: 74))

for item in loaded {
    apply(gain, to: item.buf)

    let dest = "\(outDir)/\(item.name).aiff"
    let url = URL(fileURLWithPath: dest)
    try? fm.removeItem(at: url)
    do {
        let out = try AVAudioFile(forWriting: url,
                                  settings: settings(item.buf.format.sampleRate,
                                                     Int(item.buf.format.channelCount)))
        try out.write(from: item.buf)
    } catch {
        FileHandle.standardError.write("写 \(dest) 失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let size = (try? fm.attributesOfItem(atPath: dest))?[.size] as? Int ?? 0
    print(String(format: "%-6@ 峰值 %6.1f → %5.1f dBFS   RMS %6.1f → %5.1f dBFS   响度 %+.1f dB   %@ KB",
                 item.name as NSString,
                 dB(Double(item.before)), dB(Double(peak(of: item.buf))),
                 dB(item.rmsBefore), dB(rms(of: item.buf)),
                 dB(rms(of: item.buf)) - dB(item.rmsBefore),
                 "\(size / 1024)" as NSString))
}

// ---- 3. 自检：放完不该有削波 ----
let worst = loaded.map { peak(of: $0.buf) }.max() ?? 0
guard worst <= 1.0 else {
    FileHandle.standardError.write("✗ 有样本越界（峰值 \(worst)），增益给大了\n".data(using: .utf8)!)
    exit(1)
}
print(String(repeating: "-", count: 74))
print(String(format: "已写出 %@/ —— 最大峰值 %.1f dBFS，无削波", outDir, dB(Double(worst))))
