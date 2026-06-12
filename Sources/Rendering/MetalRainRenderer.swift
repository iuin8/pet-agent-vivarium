import AppKit
import Metal
import MetalKit
import QuartzCore

/// 雨粒子的 Metal MTKView 容器,挂在 `DesktopOverlayView` 内,跟
/// `MetalSnowOverlayView` 平级。
///
/// 责任:
/// - 创建 + 拥有 `MTKView` (透明背景 + bgra8Unorm + framebufferOnly=false)
/// - 拥有 `GPURainCoordinator`(粒子 buffer + compute pipeline + render
///   pipeline + simulation state)的引用,每帧 draw 时同时 encode
///   compute pass + render pass。
/// - `submitRainParticleBuffer` 是兼容接口,雨走 GPU-only 路径无 CPU
///   buffer 上传需求,留个空壳让 DesktopOverlayView 对称。
///
/// **不动 Snow 任何文件** — Rain 是平行 pipeline,跟 Snow 完全独立。
@MainActor
public final class MetalRainRenderer: MTKView {
    public private(set) var coordinator: GPURainCoordinator?

    /// 工厂方法。Headless / 无 GPU 环境返回 nil,调用者 fallback 到 CPU
    /// CALayer 路径或直接禁用。
    public static func make(frame: CGRect) -> MetalRainRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        return MetalRainRenderer(frame: frame, metalDevice: device)
    }

    private init(frame: CGRect, metalDevice: MTLDevice) {
        super.init(frame: frame, device: metalDevice)
        configureView()
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func configureView() {
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
    }

    /// 把 coordinator 挂上来。后续每帧 `draw` 会调用 coordinator.encodeFrame。
    /// 传 nil 解绑(雨关闭时)。
    public func attach(coordinator: GPURainCoordinator?) {
        self.coordinator = coordinator
    }

    /// 启动雨 — coordinator spawn 2048 颗主雨。subsequent `draw` 直接渲染。
    public func startRain() {
        coordinator?.start()
        setNeedsDisplay(bounds)
    }

    /// 停止雨 — 静默清空 active count,粒子保留在 buffer 里但 kernel 不再
    /// 触发(particle_count = 0)。
    public func stopRain() {
        coordinator?.stop()
        setNeedsDisplay(bounds)
    }

    /// Coordinator 每帧调一次,告诉 view "你该重画"。tick 完才能拿到最新
    /// uniforms 给 draw 用。
    public func requestRedraw() {
        setNeedsDisplay(bounds)
    }

    public override func draw(_ dirtyRect: CGRect) {
        guard
            let coordinator,
            let descriptor = currentRenderPassDescriptor,
            let drawable = currentDrawable,
            let commandBuffer = coordinator.commandQueue.makeCommandBuffer()
        else {
            return
        }
        let viewportWidth = Float(bounds.width)
        let viewportHeight = Float(bounds.height)
        coordinator.encodeFrame(
            into: commandBuffer,
            renderPassDescriptor: descriptor,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
