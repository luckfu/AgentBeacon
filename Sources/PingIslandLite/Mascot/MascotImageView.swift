import AppKit
import CoreImage
import Foundation

/// 用 NSImageView 播放 GIF 的轻量封装，专门塞进 NSMenuItem 的 view 里。
///
/// macOS 12 上 SwiftUI 的 `Canvas` API 还不存在，原版 MascotView 那套像素绘制状态机
/// 没法直接搬。但是 GIF 文件可以——`NSImage(contentsOf:)` 解码 GIF 后丢给 NSImageView，
/// 它会自动按 GIF 内嵌的帧延迟循环播放（依赖 `NSBitmapImageRep` 的能力，macOS 10.6+ 就有）。
///
/// 阶段 2 第二刀（当前）：在基础 GIF 上叠"心情"信号——
/// - `working`：右下角 `NSProgressIndicator` 转圈圈
/// - `warning`：吉祥物外圈红色脉冲光晕（`CALayer.shadowOpacity` + `CABasicAnimation`）
/// - `idle`：纯 GIF
final class MascotImageView: NSView {

    // MARK: - 公开属性

    /// 当前显示的吉祥物。set 之后立刻重新加载 GIF + 同步标题。
    var kind: MascotKind = .defaultIdle {
        didSet {
            guard kind != oldValue else { return }
            reloadImage()
            refreshTitle()
        }
    }

    /// 吉祥物当前心情。set 之后立刻同步叠加层（spinner / halo）。
    var status: MascotStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            applyStatusOverlays()
            refreshTitle()
        }
    }

    // MARK: - 内部子视图

    private let imageView: NSImageView
    private let titleLabel: NSTextField
    private let spinner: NSProgressIndicator

    /// warning 状态下的红色光晕。独立 CALayer，插在 imageView 后面，
    /// 避免 NSImageView 刷新 GIF 帧时把同 layer 上的 shadow 覆盖掉。
    private let haloLayer: CALayer

    private let mascotSize: CGFloat
    private let showsTitle: Bool

    // MARK: - 生命周期

    init(kind: MascotKind = .defaultIdle, status: MascotStatus = .idle, mascotSize: CGFloat = 64, showsTitle: Bool = true) {
        self.imageView = NSImageView(frame: .zero)
        self.titleLabel = NSTextField(labelWithString: "")
        self.spinner = NSProgressIndicator(frame: .zero)
        self.haloLayer = CALayer()
        self.mascotSize = mascotSize
        self.showsTitle = showsTitle

        // 计算总尺寸：吉祥物 mascotSize + 文字行 + 边距
        let labelHeight: CGFloat = showsTitle ? 18 : 0
        let padding: CGFloat = 8
        let totalWidth: CGFloat = showsTitle ? max(mascotSize + padding * 2, 200) : mascotSize
        let totalHeight: CGFloat = showsTitle ? mascotSize + labelHeight + padding * 3 : mascotSize

        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        self.kind = kind
        self.status = status

        // self 必须 wantsLayer，才能把 haloLayer 插入 self.layer。
        self.wantsLayer = true

        // 0) Halo 层（红色圆形光晕，插在 imageView 后面）
        let haloPadding: CGFloat = 10
        let haloFrame = NSRect(
            x: (totalWidth - mascotSize) / 2 - haloPadding,
            y: (showsTitle ? labelHeight + padding * 2 : 0) - haloPadding,
            width: mascotSize + haloPadding * 2,
            height: mascotSize + haloPadding * 2
        )
        haloLayer.frame = haloFrame
        haloLayer.backgroundColor = NSColor.systemRed.cgColor
        haloLayer.cornerRadius = haloFrame.width / 2
        haloLayer.opacity = 0  // 默认隐藏，applyStatusOverlays 控制显隐
        haloLayer.masksToBounds = false
        // 轻微模糊让光晕软一点。NSCore Image 滤镜在老 macOS 也可用。
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setDefaults()
            blur.setValue(6, forKey: "inputRadius")
            haloLayer.filters = [blur]
        }
        layer?.addSublayer(haloLayer)

        // 1) GIF 容器
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = NSRect(
            x: (totalWidth - mascotSize) / 2,
            y: showsTitle ? labelHeight + padding * 2 : 0,
            width: mascotSize,
            height: mascotSize
        )
        // 必须 wantsLayer 才能跑 CABasicAnimation 做 warning 光晕。
        imageView.wantsLayer = true
        addSubview(imageView)

        // 2) 右下角 spinner（默认隐藏，working 时显示）
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let spinnerSize: CGFloat = 16
        spinner.frame = NSRect(
            x: imageView.frame.maxX - spinnerSize,
            y: imageView.frame.minY,
            width: spinnerSize,
            height: spinnerSize
        )
        addSubview(spinner)

        // 3) 标题文字
        if showsTitle {
            titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .center
            titleLabel.frame = NSRect(
                x: padding,
                y: padding,
                width: totalWidth - padding * 2,
                height: labelHeight
            )
            addSubview(titleLabel)
        }

        reloadImage()
        refreshTitle()
        applyStatusOverlays()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MascotImageView 不支持 nib 加载——只用代码构造")
    }

    // MARK: - 内容刷新

    private func reloadImage() {
        let resourceName = kind.gifResourceName
        if let image = Self.loadGIF(named: resourceName) {
            imageView.image = image
            // NSImageView.animates 默认为 true，但保险起见显式打开。
            imageView.animates = true
        } else {
            // GIF 缺失时降级为占位文字，避免空白
            imageView.image = nil
            FileHandle.standardError.write(
                Data("[mascot] WARN: GIF resource not found: \(resourceName).gif\n".utf8)
            )
        }
    }

    private func refreshTitle() {
        guard showsTitle else { return }
        // 例：「Claude · 工作中」
        titleLabel.stringValue = "\(kind.displayName) · \(status.shortLabel)"
    }

    /// 根据 status 切 spinner 启停 + halo 脉冲动画。
    private func applyStatusOverlays() {
        switch status {
        case .idle:
            spinner.stopAnimation(nil)
            removeWarningHalo()
        case .working:
            spinner.startAnimation(nil)
            removeWarningHalo()
        case .warning:
            spinner.stopAnimation(nil)
            installWarningHalo()
        case .error:
            spinner.stopAnimation(nil)
            installWarningHalo()
        case .completed:
            spinner.stopAnimation(nil)
            removeWarningHalo()
        }
    }

    // MARK: - Warning 光晕（Timer 手动驱动脈冲）
    
    /// 为什么不用 CABasicAnimation：NSMenu 弹出后主 runloop 进入
    /// `NSEventTrackingRunLoopMode` modal session，CATransaction 不会在该 mode 下
    /// commit，所以 CABasicAnimation 看上去“静止”。换成 Timer + RunLoop.common
    /// 手动变 opacity，在 menu 弹出期间仍能 tick。
    private var haloPulseTimer: Timer?
    private var haloPulseStart: CFTimeInterval = 0
    
    private func installWarningHalo() {
        // 先停上一轮，避免重复调用叠加 timer。
        haloPulseTimer?.invalidate()
    
        haloPulseStart = CACurrentMediaTime()
        haloLayer.opacity = 0.5
    
        // 每 50ms 重算一次 opacity，0.7s 一个完整脈冲周期（0.25 ↔ 0.85）。
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = CACurrentMediaTime() - self.haloPulseStart
            let period: Double = 1.4  // 一负一正往返 = 0.7s × 2
            let phase = (elapsed.truncatingRemainder(dividingBy: period)) / period * 2 * .pi
            // sin 输出 [-1, 1] → 映射到 [0.25, 0.85]
            let normalized = (sin(phase) + 1) / 2  // [0, 1]
            let opacity = 0.25 + normalized * 0.6
            // 禁止 implicit CATransaction。否则默认 0.25s 动画会拖油近周期。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.haloLayer.opacity = Float(opacity)
            CATransaction.commit()
        }
        // 关键：schedule 到 .common，覆盖 default + eventTracking + modalPanel 多个 mode。
        RunLoop.main.add(timer, forMode: .common)
        haloPulseTimer = timer
    }
    
    private func removeWarningHalo() {
        haloPulseTimer?.invalidate()
        haloPulseTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.opacity = 0
        CATransaction.commit()
    }
    
    deinit {
        haloPulseTimer?.invalidate()
    }

    // MARK: - GIF 加载

    /// 从 SwiftPM 资源 bundle（`.process("Resources/Mascots")` 注册）里读 GIF。
    private static func loadGIF(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "gif") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
