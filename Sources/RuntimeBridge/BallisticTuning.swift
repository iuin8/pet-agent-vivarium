import Foundation

/// 弹力球抛射回弹(`.ballistic`)的可调参数 —— 全部字面量集中于此,供「设置 → 调试」实时滑块拖调
/// (拖一下立即生效,省 edit→build→install 慢循环),并经 UserDefaults 持久化。
///
/// 数据流(对齐 `FallingSandTuning`):滑块绑定 `viewModel.ballisticTuning.<字段>` → onChange
/// → `onBallisticTuningPreview` → app `saveBallisticTuning` → `petMotionController.tuning`(每帧 apply)。
/// 工厂默认 = 字段默认值;`swiftCodeSnippet()` 导出调好的值便于固化回常数。
public struct BallisticTuning: Equatable, Sendable, Codable {
    /// 重力加速度(px/s²,向下)。
    public var gravity: Double = 2600
    /// 弹性系数(0..1):撞击后法向速度保留比例。0.62 ≈ 橡胶弹球。
    public var restitution: Double = 0.62
    /// 空气阻力(每秒线性衰减):每帧 v *= max(0, 1 - airDrag*dt)。
    public var airDrag: Double = 0.35
    /// 切向摩擦:撞击时平行撞击面的速度保留比例(轻微)。
    public var tangentFriction: Double = 0.9
    /// |v| 低于此(px/s)且有支撑(地面/窗口顶)→ 落定,退出抛射。
    public var settleSpeed: Double = 90
    /// 释放甩出速度上限(px/s):防极快拖拽合成超高速穿透薄窗。
    public var maxLaunchSpeed: Double = 4200

    public init() {}

    /// 把当前(调好的)值打成 Swift 字段初值片段,便于粘回 `BallisticTuning` 固化默认。
    public func swiftCodeSnippet() -> String {
        func f(_ v: Double) -> String { String(format: "%g", v) }
        return """
        public var gravity: Double = \(f(gravity))
        public var restitution: Double = \(f(restitution))
        public var airDrag: Double = \(f(airDrag))
        public var tangentFriction: Double = \(f(tangentFriction))
        public var settleSpeed: Double = \(f(settleSpeed))
        public var maxLaunchSpeed: Double = \(f(maxLaunchSpeed))
        """
    }
}
