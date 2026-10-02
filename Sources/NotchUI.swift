import SwiftUI
import AppKit

// MARK: - 尺寸与状态

final class UIState: ObservableObject {
    @Published var expanded = false
    /// 动画进度：0 = 收起，1 = 展开。显式驱动，避免依赖隐式 frame 插值的锚点行为
    @Published var progress: CGFloat = 0
    /// 面板可见行数（由控制器按数据同步）
    @Published var rows = 6

    let headerHeight: CGFloat = 35
    let footerHeight: CGFloat = 43
    let rowHeight: CGFloat = 49

    /// 面板可见宽度
    let panelWidth: CGFloat = 420
    /// 收起时把手尺寸
    let tabSize = CGSize(width: 32, height: 68)

    /// 形状外圈留白：给告警光晕和反角留绘制空间。右边缘不留（直接贴屏幕）。
    ///
    /// 必须容得下光晕的完整衰减。`.shadow(radius: 18)` 的可视范围约 38pt，
    /// 留白小于它就会在窗口边界被硬切 —— 表现为光晕最外圈有一道不自然的断口。
    /// 留白靠「空闲时窗口不接收鼠标事件」来避免白白吞掉点击。
    let edgeMargin: CGFloat = 44
    /// 右边缘距屏幕的距离；0 = 贴边（配合反角，视觉上「焊」进屏幕边缘）
    let rightGap: CGFloat = 0

    /// 把手 32 宽配 16 圆角 = 胶囊
    let tabCornerRadius: CGFloat = 16
    /// 展开态的圆角，比按比例算出来的大一些，否则在 420 宽上看着像直角
    let panelCornerRadius: CGFloat = 26

    /// 右边缘与屏幕上/下边交界处的反角（凹角）半径。
    /// 形状的边缘不是被切断，而是用一段凹曲线向上/向下翘起融进屏幕边缘。
    /// 必须 ≤ edgeMargin，否则翘出的部分会被窗口裁掉。
    let tabNotchRadius: CGFloat = 8
    let panelNotchRadius: CGFloat = 14

    /// 把手形状顶边距屏幕顶部
    var shapeTopOffset: CGFloat = 104

    // MARK: 底栏按钮（固定宽度，好让点击命中可以精确算出来）

    let footerPadding: CGFloat = 12
    let footerSpacing: CGFloat = 6
    /// 左起三个按钮宽度：WorkBuddy / 刷新 / 声音
    let footerLeftWidths: [CGFloat] = [88, 64, 76]
    /// 最右「退出」按钮宽度
    let footerQuitWidth: CGFloat = 62

    /// 底栏各按钮在「形状内」的 x 区间（0 = 形状左边缘）
    var footerZones: [(index: Int, range: ClosedRange<CGFloat>)] {
        var out: [(Int, ClosedRange<CGFloat>)] = []
        var x = footerPadding
        for (i, w) in footerLeftWidths.enumerated() {
            out.append((i, x...(x + w)))
            x += w + footerSpacing
        }
        let qx = panelWidth - footerPadding - footerQuitWidth
        out.append((footerLeftWidths.count, qx...(qx + footerQuitWidth)))
        return out
    }

    /// 面板形状高度跟着行数走，避免大片空白
    var expandedHeight: CGFloat {
        headerHeight + CGFloat(max(rows, 2)) * rowHeight + footerHeight
    }

    /// 形状尺寸（不含留白）
    var collapsedShape: CGSize { tabSize }
    var expandedShape: CGSize { CGSize(width: panelWidth, height: expandedHeight) }

    /// 窗口 / 容器尺寸 = 形状 + 左侧留白 + 右侧留白
    var collapsedSize: CGSize {
        CGSize(width: tabSize.width + edgeMargin + rightGap,
               height: tabSize.height + edgeMargin * 2)
    }
    var expandedSize: CGSize {
        CGSize(width: panelWidth + edgeMargin + rightGap,
               height: expandedHeight + edgeMargin * 2)
    }

    /// 当前形态下窗口的尺寸
    var windowSize: CGSize { expanded ? expandedSize : collapsedSize }

    /// 窗口顶边距屏幕顶部（留白会把形状往下推，所以要减掉）
    var windowTopOffset: CGFloat { shapeTopOffset - edgeMargin }

    var width: CGFloat { windowSize.width }
    var height: CGFloat { windowSize.height }
}

/// 右侧贴屏幕、带反角的形状。
///
/// 左 / 上 / 下用普通圆角；右边缘**直接贴屏幕**，
/// 并在与上、下边交界处用一段**反角（凹曲线）**向上 / 向下翘起融进屏幕边缘。
/// 这样形状看上去是从屏幕边缘「长出来」的，而不是被一刀切断。
struct DockShape: Shape {
    var cornerRadius: CGFloat
    var notchRadius: CGFloat
    /// false = 只画上、左、下三条边（用于告警描边）：
    /// 右边缘贴着屏幕，画上去会被窗口裁掉，看着很劣质
    var closed: Bool = true

    func path(in rect: CGRect) -> Path {
        let r  = min(cornerRadius, rect.height / 2, rect.width / 2)
        let nr = min(notchRadius, rect.width / 3, rect.height / 3)
        var p = Path()

        if !closed {
            // 只排除贴屏的那段直边，反角本身要描：
            // 从右上反角贴屏幕的一端起笔，绕上/左/下，收在右下反角贴屏幕的一端。
            // 反角描出来光晕会顺着曲线收进屏幕边缘，是「长出来」的感觉；
            // 而右边缘那条直线描上去就只是屏幕边上多了一道黄线，很劣质。
            if nr > 0 {
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY - nr))
                p.addQuadCurve(to: CGPoint(x: rect.maxX - nr, y: rect.minY),
                               control: CGPoint(x: rect.maxX, y: rect.minY))
            } else {
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                           control: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - nr, y: rect.maxY))
            if nr > 0 {
                p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY + nr),
                               control: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            return p
        }

        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - nr, y: rect.minY))

        if nr > 0 {
            // 右上反角：控制点放在直角处 → 起笔水平、收笔垂直，收进屏幕边缘
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY - nr),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + nr))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - nr, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 面板内的点击目标
enum PanelHit: Equatable {
    case row(Int)
    case footer(Int)
    case none
}

extension UIState {
    /// 把面板窗口内的点（左上角原点）映射成命中目标。
    /// 抽成纯函数是为了能离屏验证——本环境没有合成点击的权限。
    func hitTest(_ p: CGPoint, rowCount: Int) -> PanelHit {
        let leading = edgeMargin
        let shapeBottom = edgeMargin + expandedHeight
        guard p.x >= leading, p.x <= leading + panelWidth,
              p.y <= shapeBottom else { return .none }
        let sx = p.x - leading

        let footerTop = shapeBottom - footerHeight
        if p.y >= footerTop {
            for z in footerZones where z.range.contains(sx) { return .footer(z.index) }
            return .none
        }

        let rowsTop = edgeMargin + headerHeight
        guard p.y >= rowsTop, rowCount > 0 else { return .none }
        let i = Int((p.y - rowsTop) / rowHeight)
        return (i >= 0 && i < rowCount) ? .row(i) : .none
    }
}

/// 会「长出来」的背景形状。
///
/// 关键点：**锚点写在路径计算里**，不依赖 SwiftUI 的布局对齐或隐式 frame 插值。
/// 尺寸与圆角、反角都由 `progress` 线性插值，形状的右上角永远钉在容器的同一个位置，
/// 所以视觉上必然是从把手那一点往左下长出来。
/// 同一个形状同时用于背景填充、内容裁剪和告警描边，三者的几何天然一致。
struct MorphPath: Shape {
    var progress: CGFloat
    var collapsedShape: CGSize
    var expandedShape: CGSize
    var collapsedRadius: CGFloat
    var expandedRadius: CGFloat
    var collapsedNotch: CGFloat
    var expandedNotch: CGFloat
    var topInset: CGFloat
    var trailingInset: CGFloat
    /// 见 DockShape.closed
    var closed: Bool = true

    static var probeCount = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if AppDebug.on, progress > 0.001, MorphPath.probeCount < 40 {
            MorphPath.probeCount += 1
            AppDebug.log(String(format: "[path] rect=%.0f,%.0f %.0fx%.0f  progress=%.2f",
                                rect.minX, rect.minY, rect.width, rect.height, Double(progress)))
        }
        let t = min(max(progress, 0), 1)
        let w  = collapsedShape.width  + (expandedShape.width  - collapsedShape.width)  * t
        let h  = collapsedShape.height + (expandedShape.height - collapsedShape.height) * t
        let r  = collapsedRadius + (expandedRadius - collapsedRadius) * t
        let nr = collapsedNotch  + (expandedNotch  - collapsedNotch)  * t
        let box = CGRect(x: rect.maxX - trailingInset - w,
                         y: rect.minY + topInset,
                         width: w,
                         height: h)
        return DockShape(cornerRadius: r, notchRadius: nr, closed: closed).path(in: box)
    }
}

// MARK: - 根视图

struct DockRootView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var ui: UIState
    @ObservedObject var prefs: Preferences

    @State private var pulse = false

    private var level: AlertLevel { store.alertLevel }

    var body: some View {
        // 必须用 GeometryReader 拿真实容器尺寸，并给每个形状显式定尺寸：
        // 直接让形状去 fill 的话，ZStack 会按「形状路径的包围盒」收缩，
        // 于是动画中 path(in:) 收到的 rect 是形状自己的尺寸而不是容器尺寸，
        // rect.maxX - w 就恒等于左侧留白 —— 形状看起来从左上角长出来。
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                morphPath.fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    // 只有告警时才发光。不给黑色投影——面板外圈会多出一圈灰，
                    // 在浅色壁纸上尤其明显
                    .shadow(color: level >= .done ? level.color.opacity(pulse ? 0.95 : 0.45) : .clear,
                            radius: ui.expanded ? 0 : 18)

                // 内容按同一形状裁剪：动画中内容不会溢出还在变小的背景
                contentLayer
                    .frame(width: size.width, height: size.height)
                    .clipShape(morphPath)

                // 告警描边画在最上层，否则展开后会被面板盖住。
                // 用不闭合路径：右边缘贴屏幕不描边，只描上/左/下
                if level >= .done {
                    outlinePath
                        .stroke(level.color.opacity(pulse ? 1.0 : 0.40),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: level.color.opacity(pulse ? 0.95 : 0.35), radius: 7)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.25), value: level)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// 唯一的几何来源：背景填充与内容裁剪用它（闭合）
    private var morphPath: MorphPath { makeMorph(closed: true) }

    /// 告警描边用它（只上/左/下三条边，右侧贴屏幕不画）
    private var outlinePath: MorphPath { makeMorph(closed: false) }

    private func makeMorph(closed: Bool) -> MorphPath {
        MorphPath(progress: ui.progress,
                  collapsedShape: ui.collapsedShape,
                  expandedShape: ui.expandedShape,
                  collapsedRadius: ui.tabCornerRadius,
                  expandedRadius: ui.panelCornerRadius,
                  collapsedNotch: ui.tabNotchRadius,
                  expandedNotch: ui.panelNotchRadius,
                  topInset: ui.edgeMargin,
                  trailingInset: ui.rightGap,
                  closed: closed)
    }

    /// 内容层：加一圈和形状相同的留白，于是内容正好落在形状内部
    private var contentLayer: some View {
        Group {
            if ui.expanded {
                PanelBody(store: store, ui: ui, prefs: prefs)
                    .frame(width: ui.panelWidth, height: ui.expandedHeight, alignment: .top)
                    .transition(.opacity)
            } else {
                SideTab(level: level, count: store.alertCount, pulsing: pulse,
                        running: store.tasks.contains { $0.state.isActive })
                    .frame(width: ui.tabSize.width, height: ui.tabSize.height)
            }
        }
        .padding(EdgeInsets(top: ui.edgeMargin, leading: ui.edgeMargin,
                            bottom: ui.edgeMargin, trailing: ui.rightGap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

}

// 收起时的把手（胶囊形状）
private struct SideTab: View {
    var level: AlertLevel
    var count: Int
    var pulsing: Bool
    var running: Bool

    var body: some View {
        VStack(spacing: 8) {
            if running {
                Circle()
                    .fill(TaskState.running.color)
                    .frame(width: 8, height: 8)
                    .opacity(pulsing ? 1.0 : 0.30)
            } else {
                Circle()
                    .fill(Color(white: 0.30))
                    .frame(width: 8, height: 8)
            }

            if level >= .done {
                AlertDot(level: level, count: count, pulsing: pulsing)
            } else {
                Capsule()
                    .fill(Color(white: 0.30))
                    .frame(width: 3.5, height: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 告警角标：比原来大一圈，并带同色光晕
private struct AlertDot: View {
    var level: AlertLevel
    var count: Int
    var pulsing: Bool

    private var text: String {
        if count > 0 { return "\(min(count, 99))" }
        return level == .confirm ? "!" : "✓"
    }

    var body: some View {
        Text(text)
            .font(.system(size: count > 9 ? 10 : 13, weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(level.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
            // 光晕半径收小：把手只有 32 宽、右侧还贴着屏幕，
            // 半径大了会溢到贴屏的那条边上，看着像边缘在闪
            .shadow(color: level.color.opacity(pulsing ? 1.0 : 0.5), radius: 3)
            .shadow(color: level.color.opacity(pulsing ? 0.75 : 0.25), radius: 6)
            .scaleEffect(pulsing ? 1.0 : 0.88)
    }
}

// MARK: - 展开面板

struct PanelBody: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var ui: UIState
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.10))
            content
            Divider().overlay(Color.white.opacity(0.10))
            footer
        }
        .background(Color.black)
    }

    /// 中间区域：正常时是任务行，异常/空时是提示
    @ViewBuilder
    private var content: some View {
        if !store.isLive {
            emptyState(text: store.statusText, icon: "exclamationmark.triangle")
        } else if store.tasks.isEmpty {
            emptyState(text: "暂无最近任务", icon: "moon.zzz")
        } else {
            VStack(spacing: 0) {
                ForEach(store.tasks) { task in
                    TaskRow(task: task)
                    if task.id != store.tasks.last?.id {
                        Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 34)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("任务坞")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if store.activeTotal > 0 {
                CountChip(text: "\(store.activeTotal) 执行中",
                          color: TaskState.running.color)
            }
            if store.confirmTotal > 0 {
                CountChip(text: "\(store.confirmTotal) 待确认",
                          color: TaskState.needConfirm.color)
            }
            Spacer()
            if let t = store.lastRefresh {
                Text(fmt(t))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.4))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "更新于 " + f.string(from: d)
    }

    private func emptyState(text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color(white: 0.4))
            Text(text).font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 底栏只负责「长什么样」，点击由控制器按 footerZones 精确命中——
    /// 本 app 从不成为活跃 app，SwiftUI 的 Button / onTapGesture 在这种面板里收不到点击
    private var footer: some View {
        HStack(spacing: ui.footerSpacing) {
            FooterChip(icon: "arrow.up.forward.app", title: "WorkBuddy",
                       width: ui.footerLeftWidths[0])
            FooterChip(icon: "arrow.clockwise", title: "刷新",
                       width: ui.footerLeftWidths[1])
            FooterChip(icon: prefs.notifySound ? "speaker.wave.2.fill" : "speaker.slash.fill",
                       title: prefs.notifySound ? "声音开" : "声音关",
                       width: ui.footerLeftWidths[2],
                       on: prefs.notifySound)
            Spacer(minLength: 0)
            FooterChip(icon: "power", title: "退出", width: ui.footerQuitWidth)
        }
        .padding(.horizontal, ui.footerPadding)
        .frame(height: ui.footerHeight - 1)
        .background(Color.white.opacity(0.03))
    }
}

private struct CountChip: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

private struct FooterChip: View {
    var icon: String
    var title: String
    var width: CGFloat
    var on: Bool = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(on ? Color(white: 0.95) : Color(white: 0.62))
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(hover ? 0.13 : 0.07)))
        .onHover { hover = $0 }
    }
}

// MARK: - 任务行

private struct TaskRow: View {
    var task: TaskItem
    @State private var hover = false

    /// 圆点、状态文字都按它来画，保证「等你确认」的行一眼能认出来
    private var shown: TaskState { task.displayState }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(shown.color.opacity(0.22)).frame(width: 16, height: 16)
                Circle().fill(shown.color).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.52))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SourceChip(kind: task.kind)
            VStack(alignment: .trailing, spacing: 2) {
                Text(shown.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(shown.color)
                Text(task.relativeTime)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.42))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // 需要你关注的行统一染橙黄，不跟着状态色走——
        // 否则「已完成 + 有未读」会染成绿色，和标题栏的「待确认」对不上
        .background(hover ? Color.white.opacity(0.07)
                    : (task.needsConfirm ? TaskState.needConfirm.color.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = task.detail, !d.isEmpty { parts.append(d) }
        if let n = task.cwdName { parts.append(n) }
        if task.kind == .automation { parts.append("自动化") }
        if task.kind == .claude { parts.append(task.kind.target) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

}

/// 来源标签。固定宽度，保证多行之间标签和右侧状态列都对齐
private struct SourceChip: View {
    var kind: TaskItem.Kind

    var body: some View {
        Text(kind.sourceLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(kind.sourceColor)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(kind.sourceColor.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(kind.sourceColor.opacity(0.34), lineWidth: 0.5))
            .frame(width: 72, alignment: .leading)
    }
}

// MARK: - 用户偏好

final class Preferences: ObservableObject {
    @Published var notifySound: Bool {
        didSet { UserDefaults.standard.set(notifySound, forKey: "notifySound") }
    }
    @Published var notifySystem: Bool {
        didSet { UserDefaults.standard.set(notifySystem, forKey: "notifySystem") }
    }
    @Published var showFinished: Bool {
        didSet { UserDefaults.standard.set(showFinished, forKey: "showFinished") }
    }
    @Published var maxRows: Int {
        didSet { UserDefaults.standard.set(maxRows, forKey: "maxRows") }
    }

    init() {
        let d = UserDefaults.standard
        notifySound = d.object(forKey: "notifySound") as? Bool ?? true
        notifySystem = d.object(forKey: "notifySystem") as? Bool ?? true
        showFinished = d.object(forKey: "showFinished") as? Bool ?? true
        maxRows = d.object(forKey: "maxRows") as? Int ?? 6
    }
}

// MARK: - 窗口

final class DockPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// 面板窗口默认不是 key，而且本 app 是 accessory、永远不会变成活跃 app，
/// SwiftUI 的 onTapGesture 在这种窗口里收不到点击，所以在 AppKit 层自己算行号。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onClickPoint: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let w = window, !w.isKeyWindow, w.canBecomeKey { w.makeKey() }
        let p = convert(event.locationInWindow, from: nil)
        AppDebug.log("[hit] mouseDown 视图内坐标=(\(Int(p.x)), \(Int(p.y))) flipped=\(isFlipped)")
        onClickPoint?(p)
        super.mouseDown(with: event)
    }
}

/// 负责悬停检测的容器
final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
