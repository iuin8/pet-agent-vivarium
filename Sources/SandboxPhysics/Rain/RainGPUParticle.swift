import simd

/// 雨粒子 GPU 内存布局。与 MSL 端 `GpuRainParticle` 1:1 对齐。
///
/// Stride 24 bytes (16-byte alignment friendly):
///   position    SIMD2<Float>   8 bytes  (offset 0)
///   velocity    SIMD2<Float>   8 bytes  (offset 8)
///   lifetime    Float          4 bytes  (offset 16)
///   seed        UInt32         4 bytes  (offset 20)
///
/// 雨物理刻意比雪简单 — 没有温度、相态、堆积。所有粒子共享同一
/// kernel 行为(下落 + drift + 落地 respawn),seed 是每颗粒子的 stable
/// 随机种子(不随帧变化),用来在 kernel 内 hash 出独立的 drift 相位 +
/// respawn 位置,避免所有粒子表现一致。
///
/// **Splash 子粒子复用同一 struct**:lifetime ≤ 0.15 + velocity.y > 0 ⇒
/// 视为 splash;落地后由 kernel 把 `velocity.x` 写成横向随机值、`lifetime`
/// 写成 0.1,寿命走完 → 重生为主雨。
public struct RainGPUParticle: Equatable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var lifetime: Float
    public var seed: UInt32

    public init(
        position: SIMD2<Float> = .zero,
        velocity: SIMD2<Float> = .zero,
        lifetime: Float = 0,
        seed: UInt32 = 0
    ) {
        self.position = position
        self.velocity = velocity
        self.lifetime = lifetime
        self.seed = seed
    }
}

/// 雨 simulation kernel 共用的 uniform。
///
/// 命名跟 MSL 端 `RainSimulationUniforms` 对齐。Stride 跟 16-byte 对齐
/// 友好(最大成员 SIMD2<Float> = 8 字节,Float / UInt32 也是 4 字节)。
///
/// **新增字段(任务 A 雨打窗口 collision)**:
///   `collisionRectCount`(UInt32)— kernel 内 collision rect 循环上界。
///   实际 rect 数据走独立 `MTLBuffer`(buffer index 2),uniform 只携带
///   `count`,避免每帧把 N × stride 的 rect 数据复制到 constant 内存。
public struct RainSimulationUniforms: Equatable {
    /// 自然时间步长 (秒)。kernel 端用它 scale 速度 / drift。
    public var dt: Float
    /// 世界尺寸(屏幕尺寸,单位 logical pt)。kernel respawn 时用它给 x 取模。
    public var worldSize: SIMD2<Float>
    /// 当前帧 index — kernel 端 hash 与 sin drift 相位共用。
    public var frameIndex: UInt32
    /// 有效粒子数(可以小于 buffer 容量)。kernel guard 用。
    public var particleCount: UInt32
    /// 外部 wind 基线 (px/s),来自 WeatherStateManager。雨受 wind 影响远
    /// 小于雪,所以 kernel 内部 /3 衰减。
    public var windX: Float
    /// 重力加速度 (px/s²)。雨下落比雪快得多,默认 ~1200(雪默认 120)。
    public var gravity: Float
    /// 当前活跃的 collision rect 数。kernel 端 for-loop 上界(<= 64)。
    public var collisionRectCount: UInt32
    /// 任务 #64:Snow pile cell grid 维度 (cellGridW, cellGridH)。
    /// 通过 `GPURainCoordinator.setPileBuffer` 从 `MetalSnowSimulation`
    /// 透传。`hasPileBuffer == 0` 时 kernel 忽略此字段,走 splash fallback。
    public var pileCellGridSize: SIMD2<UInt32>
    /// 任务 #64:Pile cell 在世界坐标中的物理尺寸 (px),典型 (4, 4)。
    public var pileCellSize: SIMD2<Float>
    /// 任务 #64:1 = pile buffer 已绑定到 buffer index 3,kernel 优先走
    /// water cell deposit 路径(atomic_compare_exchange 写 payload=3u),
    /// 失败时回退到 splash;0 = 没绑 pile buffer,kernel 走原 splash 路径。
    /// 用 UInt32 而非 Bool 保证 MSL 端对齐稳定(MSL bool 是 1 byte)。
    public var hasPileBuffer: UInt32

    public init(
        dt: Float,
        worldSize: SIMD2<Float>,
        frameIndex: UInt32,
        particleCount: UInt32,
        windX: Float,
        gravity: Float,
        collisionRectCount: UInt32 = 0,
        pileCellGridSize: SIMD2<UInt32> = .zero,
        pileCellSize: SIMD2<Float> = .zero,
        hasPileBuffer: UInt32 = 0
    ) {
        self.dt = dt
        self.worldSize = worldSize
        self.frameIndex = frameIndex
        self.particleCount = particleCount
        self.windX = windX
        self.gravity = gravity
        self.collisionRectCount = collisionRectCount
        self.pileCellGridSize = pileCellGridSize
        self.pileCellSize = pileCellSize
        self.hasPileBuffer = hasPileBuffer
    }
}

/// 雨 collision rect 的 GPU 端内存布局。stride 16 bytes:
///   minX(4) + minY(4) + maxX(4) + maxY(4) = 16 bytes (offset 0)
///
/// 雨用 minX/maxX/maxY/minY 表达边界:雨 kernel 只关心矩形顶部线 splash 判定，
/// 直接的边界值最适合 kernel 内 4 个比较。
///
/// 屏幕坐标 bottom-origin,跟 Rain particle 一致。`maxY` 是矩形顶 — 雨粒子从上
/// 往下跨过这条线就触发 splash。
public struct RainCollisionRect: Equatable {
    public var minX: Float
    public var minY: Float
    public var maxX: Float
    public var maxY: Float

    public init(minX: Float, minY: Float, maxX: Float, maxY: Float) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}
