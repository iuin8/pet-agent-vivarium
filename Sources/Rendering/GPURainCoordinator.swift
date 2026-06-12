import Foundation
import Metal
import simd

/// 雨 coordinator 编译时常量(类比 GPUSnowCoordinatorDefaults
/// 但极简 — 无堆积 / 温度 / SDF / 风刷)。
public enum GPURainCoordinatorDefaults {
    /// 2^11 = 2048 颗。GPU buffer 16-byte 对齐友好。
    /// 暴雨视觉常态可见 1000-3000 颗,2048 在 GPU 路径上 60fps 几乎免费。
    public static let particleCapacity: Int = 2048
    /// 重力 px/s²。1200 ≈ 200 px/frame @ 60fps 起步速,符合"暴雨快速垂直下落"。
    public static let gravity: Float = 1200
    /// 主雨 quad 宽度(屏幕 logical pt)。
    /// 2026-05-27: 1.5 → 1.0 让雨线更细更像真雨 motion blur 残影。
    public static let dropWidth: Float = 1.0
    /// 主雨 quad 最大长度(屏幕 logical pt)。
    /// 2026-05-27: 12 → 22 让雨线明显拉长,更像真雨高速下落的视觉拖影。
    /// 实际渲染长度还会被 wetnessIntensity 乘 (1 + 2×wet),wet=1 时达 66pt。
    public static let dropLength: Float = 22
    /// 任务 A 雨打窗口 collision rect 上限。kernel 内层 for-loop N 上限。
    /// 桌面常态可见 8-30 个窗口,64 上限给足余量。
    public static let collisionRectCapacity: Int = 64
    /// 任务 B vertex shader wind tilt 系数。`windTiltX = windX × ratio`。
    /// 0.5 = 风速 200 px/s 时 quad tangent X 多 +100 — 暴雨明显斜飘。
    /// **first-draft,待主 agent 截屏验证微调**(typical range 0.3-0.8)。
    public static let windTiltRatio: Float = 0.5
    /// 任务 C' wetness intensity 每帧 lerp 速度(per-frame delta toward target)。
    /// 0.02 ≈ 50 帧(约 0.83 s @ 60fps)从 0 升到 1,关雨时同速淡出。
    /// **first-draft,待主 agent 截屏验证微调**(typical range 0.01-0.05)。
    public static let wetnessLerpPerFrame: Float = 0.02
}

/// 雨 Metal pipeline 主 coordinator。
///
/// 设计跟 `GPUSnowCoordinator` 平行但极简(雨不做堆积、不做温度场、
/// 不做 SDF):
/// - 单 compute pipeline:`rain_simulation` kernel(主雨 + splash 子粒子合一)
/// - 单 render pipeline:vertex 输出 stretched quad → fragment motion blur
/// - 单粒子 buffer:`MTLBuffer × particleCapacity` of `RainGPUParticle`,
///   `.storageModeShared`(MainActor 写 seed,GPU 每帧 in-place 更新)
///
/// 接口与 `MetalRainRenderer.draw` 配套:
/// 1. App 启动时 init coordinator,attach 到 view (`view.attach(coordinator:)`)
/// 2. WeatherStateManager 路由到 `tick(dt:isRainEnabled:windX:)` —
///    Coordinator 更新 active particle count + uniforms,然后请 view 重绘
/// 3. View 的 `draw` 回调 → `encodeFrame` (compute + render)
@MainActor
public final class GPURainCoordinator {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let computePipelineState: MTLComputePipelineState
    public let renderPipelineState: MTLRenderPipelineState
    public let particleBuffer: MTLBuffer
    public let particleCapacity: Int
    public let gravity: Float
    public let dropWidth: Float
    public let dropLength: Float

    /// 任务 A 新增:collision rect buffer(`.storageModeShared`,
    /// stride 16 × `collisionRectCapacity`)。每帧 `setCollisionRects`
    /// 写入,kernel 内 for-loop 读取触发 splash 跨越判定。
    public let collisionRectBuffer: MTLBuffer
    public let collisionRectCapacity: Int
    public private(set) var activeCollisionRectCount: UInt32 = 0

    public private(set) var activeParticleCount: Int = 0
    public private(set) var frameIndex: UInt32 = 0
    public private(set) var elapsedSeconds: Double = 0
    public private(set) var lastUniforms: RainSimulationUniforms?

    /// 任务 B / C' 新增:vertex shader wind tilt 系数 + wetness lerp 状态。
    /// `windTiltRatio` 是 windX→tangent-X-bias 的比例,init 时传入。
    /// `wetnessIntensity` 由 `tick(isRainEnabled:)` 每帧朝 target lerp。
    public let windTiltRatio: Float
    public let wetnessLerpPerFrame: Float
    public private(set) var wetnessIntensity: Float = 0

    /// 由外部(MinimalAppDelegate weather onUpdate)注入的当前风速 (px/s)。
    /// `nil` → 视为无风。kernel 内会 /3 衰减(雨比雪受 wind 影响弱)。
    public var externalWindX: Float?

    /// 任务 #64:由 MinimalAppDelegate+RuntimeFrame 每帧 `setPileBuffer`
    /// 注入的 snow simulation pile cell buffer 引用 + grid 维度。
    /// nil → kernel 内 has_pile_buffer = 0 走原 splash 路径(向后兼容)。
    /// 非 nil → kernel 内 has_pile_buffer = 1,尝试把雨落 deposit 成
    /// pile water cell(payload = 3u = occupied|water),失败时回退 splash。
    ///
    /// **不持有 buffer 所有权** — 只是 reference,生命期由 MetalSnowSimulation
    /// 控制。MetalSnowSimulation 是 @MainActor + let-bound,跟 rain coordinator
    /// 同生命期,无悬挂指针风险。
    public private(set) var pileCellBuffer: MTLBuffer?
    public private(set) var pileCellGridSize: SIMD2<UInt32> = .zero
    public private(set) var pileCellSize: SIMD2<Float> = .zero

    public init?(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        particleCapacity: Int = GPURainCoordinatorDefaults.particleCapacity,
        gravity: Float = GPURainCoordinatorDefaults.gravity,
        dropWidth: Float = GPURainCoordinatorDefaults.dropWidth,
        dropLength: Float = GPURainCoordinatorDefaults.dropLength,
        collisionRectCapacity: Int = GPURainCoordinatorDefaults.collisionRectCapacity,
        windTiltRatio: Float = GPURainCoordinatorDefaults.windTiltRatio,
        wetnessLerpPerFrame: Float = GPURainCoordinatorDefaults.wetnessLerpPerFrame,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    ) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }

        // ---- compute pipeline ----
        let computeSource = [
            RainKernelShared.source,
            RainSimulationKernel.source
        ].joined(separator: "\n\n")
        guard
            let computeLibrary = try? device.makeLibrary(source: computeSource, options: nil),
            let computeFunction = computeLibrary.makeFunction(name: "rain_simulation"),
            let computeState = try? device.makeComputePipelineState(function: computeFunction)
        else {
            return nil
        }

        // ---- render pipeline ----
        guard
            let renderLibrary = try? device.makeLibrary(source: RainRenderShaderSource.source, options: nil),
            let vertexFunction = renderLibrary.makeFunction(name: "rain_vertex"),
            let fragmentFunction = renderLibrary.makeFunction(name: "rain_fragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        // 不用 MTLVertexDescriptor — vertex shader 直接 instance_id 拉粒子,
        // 4-vertex triangle strip 由 vertex_id 算 corner。
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let renderState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        // ---- particle buffer ----
        let particleBytes = particleCapacity * MemoryLayout<RainGPUParticle>.stride
        guard let pBuffer = device.makeBuffer(length: particleBytes, options: [.storageModeShared]) else {
            return nil
        }

        // ---- collision rect buffer ----
        // max(1, capacity) — Metal `makeBuffer(length:0)` 返回 nil。
        let safeRectCap = max(1, collisionRectCapacity)
        let rectBytes = safeRectCap * MemoryLayout<RainCollisionRect>.stride
        guard let cBuffer = device.makeBuffer(length: rectBytes, options: [.storageModeShared]) else {
            return nil
        }
        // 零填充避免初始未定义内存被 kernel 当作真 rect 用。
        memset(cBuffer.contents(), 0, rectBytes)

        self.device = device
        self.commandQueue = queue
        self.computePipelineState = computeState
        self.renderPipelineState = renderState
        self.particleBuffer = pBuffer
        self.particleCapacity = particleCapacity
        self.gravity = gravity
        self.dropWidth = dropWidth
        self.dropLength = dropLength
        self.collisionRectBuffer = cBuffer
        self.collisionRectCapacity = safeRectCap
        self.windTiltRatio = windTiltRatio
        self.wetnessLerpPerFrame = wetnessLerpPerFrame

        seedDeterministic()
    }

    /// 任务 #64:每帧由 MinimalAppDelegate+RuntimeFrame 调用,注入
    /// snow simulation 的 pile cell buffer + grid 参数。传 nil 解绑
    /// (雪未启用 / Metal 不可用)— kernel 端 has_pile_buffer 转 0 走
    /// 旧 splash 路径。
    ///
    /// 多次调用幂等 — 只更新引用,不触发任何 GPU 操作。
    public func setPileBuffer(
        _ buffer: MTLBuffer?,
        gridSize: SIMD2<UInt32>,
        cellSize: SIMD2<Float>
    ) {
        pileCellBuffer = buffer
        pileCellGridSize = gridSize
        pileCellSize = cellSize
    }

    /// 任务 A:每帧由外部(MinimalAppDelegate+RuntimeFrame)同步当前
    /// 桌面 collision rects(跟雪 pipeline 同款 rect 列表)给 rain kernel。
    ///
    /// 超过 capacity 的 rect 会被截断。Capacity 默认 64,在 macOS 桌面
    /// 常态可见 8-30 个窗口远不到上限。
    public func setCollisionRects(_ rects: [RainCollisionRect]) {
        let count = min(rects.count, collisionRectCapacity)
        activeCollisionRectCount = UInt32(count)
        guard count > 0 else { return }
        let raw = collisionRectBuffer.contents().bindMemory(
            to: RainCollisionRect.self, capacity: collisionRectCapacity
        )
        for i in 0..<count { raw[i] = rects[i] }
    }

    /// 初始化粒子 buffer。所有粒子 lifetime = 0 + position.y < 0 → kernel
    /// 第一帧的 respawn 分支会给每颗发个随机 (x, y) 顶部位置。无 Swift-side
    /// 位置布局(避免"一整排雨同时落"的 slab 视觉)。
    public func seedDeterministic() {
        let ptr = particleBuffer.contents().bindMemory(
            to: RainGPUParticle.self,
            capacity: particleCapacity
        )
        for i in 0..<particleCapacity {
            // 给每颗 stable seed(随 buffer index 决定,跨帧不变)。
            // 用 splitmix-ish hash 让序号相邻的两颗 seed 看起来不相关。
            let h = UInt32(truncatingIfNeeded: (UInt64(i) &* 0x9E3779B97F4A7C15) >> 32)
            ptr[i] = RainGPUParticle(
                position: SIMD2<Float>(0, -1),
                velocity: SIMD2<Float>(0, -1),  // 朝下 → kernel 视为主雨
                lifetime: 0,
                seed: h
            )
        }
        activeParticleCount = 0
        frameIndex = 0
        elapsedSeconds = 0
        lastUniforms = nil
    }

    /// 启动雨 — active count 拉满到 capacity。视觉上瞬间 spawn 2048 颗。
    public func start() {
        activeParticleCount = particleCapacity
    }

    /// 停止雨 — active count 清零,kernel 跳过所有粒子,render 实例数也是 0。
    /// 不擦 buffer:下次 start 时 kernel 看到 lifetime ≤ 0 会 respawn 顶部,
    /// 视觉上跟全新启动一样,免去清零开销。
    public func stop() {
        activeParticleCount = 0
    }

    /// Per-frame tick:更新 frameIndex / elapsed,产出 uniforms 写到 `lastUniforms`。
    /// `MetalRainRenderer.draw` 会回调 `encodeFrame` 真正下发 GPU 命令。
    ///
    /// - Parameters:
    ///   - dt: 自然时间步 (秒)。会被 clamp 到 [0, 1/30] 防大跳后粒子穿屏。
    ///   - isRainEnabled: 切换雨开关。开 → 拉满 active,关 → 清零。
    ///   - windX: 当前风速 px/s。**已经**是 px 空间(WeatherStateManager 已 ×2.5)。
    @discardableResult
    public func tick(
        dt: Double,
        isRainEnabled: Bool,
        windX: Float
    ) -> RainSimulationUniforms {
        let safeDt = max(0, min(dt, 1.0 / 30.0))
        if isRainEnabled {
            if activeParticleCount == 0 {
                activeParticleCount = particleCapacity
            }
            elapsedSeconds += safeDt
        } else {
            activeParticleCount = 0
        }
        frameIndex &+= 1

        // 任务 C':wetness 朝 target lerp。雨开 → 1,雨关 → 0,
        // 每帧 step `wetnessLerpPerFrame`。clamp 到 [0, 1] 防数值飘。
        let target: Float = isRainEnabled ? 1 : 0
        if wetnessIntensity < target {
            wetnessIntensity = min(target, wetnessIntensity + wetnessLerpPerFrame)
        } else if wetnessIntensity > target {
            wetnessIntensity = max(target, wetnessIntensity - wetnessLerpPerFrame)
        }

        let effectiveWind = externalWindX ?? windX
        let uniforms = RainSimulationUniforms(
            dt: Float(safeDt),
            worldSize: SIMD2<Float>(1, 1),  // 占位 — 真正写入在 encodeFrame
            frameIndex: frameIndex,
            particleCount: UInt32(activeParticleCount),
            windX: effectiveWind,
            gravity: gravity,
            collisionRectCount: activeCollisionRectCount,
            pileCellGridSize: pileCellGridSize,
            pileCellSize: pileCellSize,
            hasPileBuffer: pileCellBuffer != nil ? 1 : 0
        )
        lastUniforms = uniforms
        return uniforms
    }

    /// 渲染回调 — `MetalRainRenderer.draw` 触发。同一个 commandBuffer 内
    /// 先 compute (rain_simulation) 再 render (4-vertex strip × activeCount
    /// instances)。
    public func encodeFrame(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        viewportWidth: Float,
        viewportHeight: Float
    ) {
        // tick 没跑过(view 在 coordinator 没 tick 时被强制 draw)— 直接清屏
        // 不做任何 compute / render。viewport 必须 > 0 否则跳过(headless / 0 size)。
        guard
            viewportWidth > 0, viewportHeight > 0,
            var uniforms = lastUniforms,
            activeParticleCount > 0
        else {
            // 还是要触发清屏 — 让 render pass clearColor 把 view 刷成透明。
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            return
        }

        // ----- compute pass -----
        uniforms.worldSize = SIMD2<Float>(viewportWidth, viewportHeight)
        uniforms.collisionRectCount = activeCollisionRectCount
        // 任务 #64:把 pile 引用同步进 uniforms,kernel 端 has_pile_buffer
        // 决定走 deposit 还是 splash。pileCellBuffer 是 MTLBuffer? 引用,
        // 解析后填入 uniforms;实际 buffer 在下方 index 3 绑定。
        uniforms.pileCellGridSize = pileCellGridSize
        uniforms.pileCellSize = pileCellSize
        uniforms.hasPileBuffer = pileCellBuffer != nil ? 1 : 0
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            withUnsafePointer(to: &uniforms) { ptr in
                computeEncoder.setBytes(
                    ptr,
                    length: MemoryLayout<RainSimulationUniforms>.stride,
                    index: 1
                )
            }
            // 任务 A:collision rect buffer 绑到 index 2(对齐 SnowSimulation
            // kernel 同款编号 — rain 也用 index 2)。即使 count==0 也绑
            // buffer 防 Metal validation crash;kernel 内 for-loop count 上界
            // 自然跳过。
            computeEncoder.setBuffer(collisionRectBuffer, offset: 0, index: 2)
            // 任务 #64:pile cell atomic buffer 绑到 index 3。Metal 要求
            // 即使 has_pile_buffer == 0 也必须绑某个 buffer(kernel signature
            // 已经声明 buffer[3]),否则 validation crash。fallback 复用
            // collisionRectBuffer(同 storageModeShared,内容不被读),纯
            // 为避免 nil binding;kernel guard `has_pile_buffer == 0` 会
            // 在第一行 return false 不读它。
            let pileBinding = pileCellBuffer ?? collisionRectBuffer
            computeEncoder.setBuffer(pileBinding, offset: 0, index: 3)
            let threadCount = activeParticleCount
            let threadsPerGroup = MTLSize(
                width: computePipelineState.maxTotalThreadsPerThreadgroup,
                height: 1, depth: 1
            )
            let groupCount = MTLSize(
                width: (threadCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: 1, depth: 1
            )
            computeEncoder.dispatchThreadgroups(groupCount, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // ----- render pass -----
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        // 任务 B:windTiltX = effectiveWind × ratio,放大 wind 对 quad 倾斜
        // 角度的影响。任务 C':wetnessIntensity → fragment 端拖长 alpha tail。
        let effectiveWind = externalWindX ?? uniforms.windX
        var renderUniforms = RainRenderUniforms(
            viewportSize: SIMD2<Float>(viewportWidth, viewportHeight),
            dropWidth: dropWidth,
            dropLength: dropLength,
            windTiltX: effectiveWind * windTiltRatio,
            wetnessIntensity: wetnessIntensity
        )
        withUnsafePointer(to: &renderUniforms) { ptr in
            renderEncoder.setVertexBytes(
                ptr,
                length: MemoryLayout<RainRenderUniforms>.stride,
                index: 1
            )
            // fragment 同款 uniforms:wetness 控制 tail alpha,vertex /
            // fragment 都需要,绑到 fragment index 1。
            renderEncoder.setFragmentBytes(
                ptr,
                length: MemoryLayout<RainRenderUniforms>.stride,
                index: 1
            )
        }
        renderEncoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: activeParticleCount
        )
        renderEncoder.endEncoding()
    }

    /// 测试用:读当前 buffer 里前 N 颗粒子的快照。`.storageModeShared` →
    /// CPU 直接可读,无需 GPU sync(测试已等 commandBuffer.waitUntilCompleted)。
    public func snapshot(count: Int) -> [RainGPUParticle] {
        let n = min(count, particleCapacity)
        let ptr = particleBuffer.contents().bindMemory(
            to: RainGPUParticle.self,
            capacity: particleCapacity
        )
        return (0..<n).map { ptr[$0] }
    }

    /// 测试用:读当前 collision rect buffer 里前 N 个 rect 的快照。
    public func collisionRectsSnapshot(count: Int) -> [RainCollisionRect] {
        let n = min(count, collisionRectCapacity)
        let ptr = collisionRectBuffer.contents().bindMemory(
            to: RainCollisionRect.self,
            capacity: collisionRectCapacity
        )
        return (0..<n).map { ptr[$0] }
    }
}

/// Render shader uniforms — Swift 端镜像 MSL `RainRenderUniforms`。
/// 字段(24 字节,4-byte 对齐):
///   viewportSize(8) + dropWidth(4) + dropLength(4)
///   + windTiltX(4) + wetnessIntensity(4) = 24 bytes
///
/// 新增字段:
/// - `windTiltX`:**额外**叠加到 vertex shader 的 tangent X 分量,把
///   雨 quad 拍倾斜得更明显。单位 px/s,典型 0.3-0.8 × windX。0 = 无
///   额外倾斜,只跟 velocity 走。
/// - `wetnessIntensity`:0..1。控制每颗雨粒子尾部"水痕"残影的强度。
///   方案 C':在 fragment 端把 quad 拉得更长 / alpha tail 拖得更
///   远,模拟玻璃湿润感。Coordinator 端每帧 lerp 趋近 isRainEnabled
///   ? 1 : 0,避免雨开关瞬间硬切。
public struct RainRenderUniforms: Equatable {
    public var viewportSize: SIMD2<Float>
    public var dropWidth: Float
    public var dropLength: Float
    public var windTiltX: Float
    public var wetnessIntensity: Float

    public init(
        viewportSize: SIMD2<Float>,
        dropWidth: Float,
        dropLength: Float,
        windTiltX: Float = 0,
        wetnessIntensity: Float = 0
    ) {
        self.viewportSize = viewportSize
        self.dropWidth = dropWidth
        self.dropLength = dropLength
        self.windTiltX = windTiltX
        self.wetnessIntensity = wetnessIntensity
    }
}
