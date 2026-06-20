import Foundation

/// 活动态防抖器 —— 复刻 petdex `state-queue` 的 min-dwell 机制。
///
/// 纯值类型，不取系统时钟；调用方通过 `now` 参数传入单调时间（秒），
/// 便于单元测试确定性重放。
///
/// ## 判定顺序（submit 内部）
/// 1. 首次（无 lastShown）→ 放行。
/// 2. requested == lastShown → nil（同态合并，不重复刷视觉）。
/// 3. 当前在 transient 保持期内（now < holdUntil）→ nil（动画放完前不打断）。
/// 4. now - lastShownAt < minDwellSeconds → nil（太快，防抖吞掉）。
/// 5. 否则 → 放行，更新状态；若新态为 transient，记录 holdUntil。
///
/// ## 常量
/// - `minDwellSeconds`：每态最短停留时间，对齐 petdex `MIN_DWELL_MS=250`。
/// - transient 态（`.celebrating`/`.failed`）保持其各自 duration，期间不可打断。
public struct ActivityCoalescer {

    // MARK: - 公开常量

    /// 每态最短停留时长（秒）。对齐 petdex MIN_DWELL_MS = 250ms。
    public static let minDwellSeconds: TimeInterval = 0.25

    // MARK: - 私有状态

    /// 当前正在显示的视觉态（nil = 从未显示过）。
    private var lastShown: PetActivityVisual?

    /// lastShown 最近一次放行时的时间戳（秒）。
    private var lastShownAt: TimeInterval = 0

    /// transient 态最早可被切换的时间戳（nil = 无保持期）。
    private var holdUntil: TimeInterval?

    // MARK: - 初始化

    public init() {}

    // MARK: - 提交接口

    /// 提交一个请求态，返回「应实际显示的态」；被防抖吞掉时返回 nil。
    ///
    /// - Parameters:
    ///   - requested: 希望切换到的视觉态。
    ///   - now: 当前单调时钟（秒），由调用方传入。
    /// - Returns: 实际应渲染的态；nil 表示调用方不应更新视觉。
    public mutating func submit(_ requested: PetActivityVisual, now: TimeInterval) -> PetActivityVisual? {
        // 1. 首次提交 → 直接放行
        guard let current = lastShown else {
            return show(requested, at: now)
        }

        // 2. 同态合并 → nil（不重复刷视觉）
        if requested == current {
            return nil
        }

        // 3. transient 保持期内 → nil（动画放完前不打断）
        if let until = holdUntil, now < until {
            return nil
        }

        // 4. min-dwell 防抖 → nil（切换太快）
        if now - lastShownAt < ActivityCoalescer.minDwellSeconds {
            return nil
        }

        // 5. 放行
        return show(requested, at: now)
    }

    // MARK: - 私有辅助

    /// 放行：更新内部状态并返回新态。
    @discardableResult
    private mutating func show(_ visual: PetActivityVisual, at now: TimeInterval) -> PetActivityVisual {
        lastShown = visual
        lastShownAt = now
        if let duration = ActivityCoalescer.transientDuration(visual) {
            holdUntil = now + duration
        } else {
            holdUntil = nil
        }
        return visual
    }

    /// transient 态保持时长表。非 transient 态返回 nil。
    ///
    /// - `.celebrating`：1.2s（跳跃动画约 1.2s 一循环）
    /// - `.failed`：0.9s（失败提示约 0.9s 后恢复）
    private static func transientDuration(_ visual: PetActivityVisual) -> TimeInterval? {
        switch visual {
        case .celebrating: return 1.2
        case .failed:      return 0.9
        default:           return nil
        }
    }
}
