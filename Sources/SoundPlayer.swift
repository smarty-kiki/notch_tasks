import AVFoundation
import AppKit

/// 提醒音。
///
/// 音量靠**音频文件本身**解决，不在播放链路上做手脚：
///
/// - 系统音效峰值只有 -14 dBFS 上下（`/System/Library/Sounds`），留了十几 dB 余量
/// - 而 `NSSound.volume` 默认就是 1.0、**上限也是 1.0**（实测设 2.0 会被 clamp 回 1.0）
///
/// 所以走播放器这条路一点提升空间都没有。`tools/make-sounds.swift` 把系统音效
/// 整体放大 **+9.6 dB**（线性 ×3.0，无损、无削波）写进 `Resources/Sounds/`，
/// 这里优先播那份；没有（比如以裸二进制跑自检）就退回系统原版。
///
/// 响度可离线核对：`NotchTasks --sound`。
final class SoundPlayer {

    static let shared = SoundPlayer()

    private var cache: [String: NSSound] = [:]

    private init() {}

    func play(_ name: String) {
        guard let s = sound(name) else { return }
        s.stop()          // 提醒密集时打断上一条，别叠在一起
        s.play()
    }

    /// 预热：首次播放要把音频读进内存，先做掉免得第一声有延迟
    func warmUp() {
        for n in ["Glass", "Ping", "Basso"] { _ = sound(n) }
    }

    // MARK: - 取音效

    private func sound(_ name: String) -> NSSound? {
        if let s = cache[name] { return s }
        guard let url = Self.url(for: name),
              // byReference: false —— 把音频读进内存，之后文件动过也不影响
              let s = NSSound(contentsOf: url, byReference: false) else {
            AppDebug.log("[sound] 找不到音效 \(name)")
            return nil
        }
        s.volume = 1.0
        cache[name] = s
        return s
    }

    /// 自带的那份优先，其次系统原版
    private static func url(for name: String) -> URL? {
        if let bundled = bundledURL(name) { return bundled }
        let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }

    /// app 自带的放大版音效。装在 .app 里时走 `Bundle.main`；
    /// 以裸二进制（`build/NotchTasks`）跑自检时，回退到源码树里的 Resources/Sounds。
    private static func bundledURL(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "aiff",
                                   subdirectory: "Sounds") {
            return u
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            exe.appendingPathComponent("../Resources/Sounds/\(name).aiff"),
            URL(fileURLWithPath: "Resources/Sounds/\(name).aiff"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 响度自证

    /// 对比「系统原版」与「自带放大版」的峰值 / RMS（dBFS）。
    /// 音量这种事不该靠耳朵猜，`NotchTasks --sound` 打的就是这张表。
    static func measure(_ name: String) -> String {
        let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let a = stats(of: system) else { return "  读不到系统音效 \(name)" }

        guard let bURL = bundledURL(name), let b = stats(of: bURL) else {
            return String(format: "  系统原版 峰值 %6.1f dBFS   RMS %6.1f dBFS\n"
                                + "  自带版  : 没找到（先在仓库根跑 `swift tools/make-sounds.swift`）",
                          dB(a.peak), dB(a.rms))
        }
        return String(
            format: "  系统原版 峰值 %6.1f dBFS   RMS %6.1f dBFS\n"
                  + "  自带放大 峰值 %6.1f dBFS   RMS %6.1f dBFS   → 响度 %+.1f dB",
            dB(a.peak), dB(a.rms), dB(b.peak), dB(b.rms),
            dB(b.rms) - dB(a.rms))
    }

    private static func stats(of url: URL) -> (peak: Double, rms: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let data = buf.floatChannelData else { return nil }

        var peak = 0.0
        var sumSq = 0.0
        var n = 0
        for c in 0..<Int(buf.format.channelCount) {
            let p = data[c]
            for i in 0..<Int(buf.frameLength) {
                let v = Double(p[i])
                peak = max(peak, abs(v))
                sumSq += v * v
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (peak, (sumSq / Double(n)).squareRoot())
    }

    private static func dB(_ v: Double) -> Double { v <= 1e-9 ? -120 : 20 * log10(v) }
}
