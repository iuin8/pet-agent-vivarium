import Testing
@testable import Rendering

// MARK: - ActivityCoalescer 防抖测试
//
// 验证：
// 1. 首次提交 → 放行
// 2. 250ms 内同态提交 → nil（同态合并）
// 3. 250ms 内异态提交 → nil（防抖吞掉）
// 4. 超 250ms 异态提交 → 放行
// 5. transient 态（.celebrating / .failed）保持期内任何异态 → nil
// 6. transient 保持期过后 → 放行
//
// 所有测试传入 `now` 参数，不依赖系统时钟（确定性）。

@Suite("ActivityCoalescer")
struct ActivityCoalescerTests {

    // MARK: - 首次提交

    @Test("首次提交任意态 → 放行并返回该态")
    func firstSubmitAlwaysAllowed() {
        var c = ActivityCoalescer()
        let result = c.submit(.idle, now: 0)
        #expect(result == .idle)
    }

    @Test("首次提交 working → 放行")
    func firstSubmitWorking() {
        var c = ActivityCoalescer()
        let result = c.submit(.working, now: 100)
        #expect(result == .working)
    }

    // MARK: - 250ms 内同态合并

    @Test("250ms 内重复提交同态 → nil（不重复刷视觉）")
    func sameStateWithinDwellReturnsNil() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        // 同态，无论时间多短或多长都应合并
        let r1 = c.submit(.idle, now: 0.1)
        let r2 = c.submit(.idle, now: 0.24)
        #expect(r1 == nil)
        #expect(r2 == nil)
    }

    @Test("相同态超过 250ms 仍返回 nil（同态永远合并）")
    func sameStateAfterDwellStillNil() {
        var c = ActivityCoalescer()
        _ = c.submit(.working, now: 0)
        // 同态：即使超过 minDwell 也无需重新显示
        let r = c.submit(.working, now: 1.0)
        #expect(r == nil)
    }

    // MARK: - 250ms 内异态防抖

    @Test("250ms 内提交异态 → nil（防抖吞掉）")
    func differentStateWithinDwellReturnsNil() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        // 100ms 内切 working → 防抖吞
        let r = c.submit(.working, now: 0.1)
        #expect(r == nil)
    }

    @Test("249ms 时提交异态 → nil（刚好未到 250ms）")
    func differentStateJustUnderDwellReturnsNil() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        let r = c.submit(.reviewing, now: 0.249)
        #expect(r == nil)
    }

    // MARK: - 超 250ms 异态放行

    @Test("恰好 250ms 时提交异态 → 放行")
    func differentStateAtExactDwellAllowed() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        let r = c.submit(.working, now: 0.25)
        #expect(r == .working)
    }

    @Test("超过 250ms 后提交异态 → 放行并更新 lastShown")
    func differentStateAfterDwellAllowed() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        let r1 = c.submit(.working, now: 0.3)
        #expect(r1 == .working)
        // 再次检查：又处于新一个 dwell 周期
        let r2 = c.submit(.idle, now: 0.4)
        #expect(r2 == nil)   // 0.3 → 0.4 只过了 100ms，仍防抖
        let r3 = c.submit(.idle, now: 0.6)
        #expect(r3 == .idle) // 0.3 → 0.6 过了 300ms，放行
    }

    // MARK: - transient 态保持期（.celebrating = 1.2s）

    @Test("celebrating 放行后，保持期内任何异态 → nil")
    func celebratingHoldUntilBlocksOthers() {
        var c = ActivityCoalescer()
        // 先进入 celebrating（transient，1.2s hold）
        let r0 = c.submit(.celebrating, now: 10.0)
        #expect(r0 == .celebrating)
        // hold 期内（< 11.2s）提交异态 → 全部吞
        let r1 = c.submit(.idle, now: 10.5)
        let r2 = c.submit(.working, now: 11.0)
        let r3 = c.submit(.failed, now: 11.19)
        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(r3 == nil)
    }

    @Test("celebrating 保持期结束后，异态可放行")
    func celebratingHoldExpiredAllowsNext() {
        var c = ActivityCoalescer()
        _ = c.submit(.celebrating, now: 10.0)
        // 11.2s 后放行（holdUntil = 10.0 + 1.2 = 11.2）
        let r = c.submit(.idle, now: 11.2)
        #expect(r == .idle)
    }

    @Test("celebrating 保持期内提交同态 → nil（同态合并优先）")
    func celebratingHoldSameStateIsNil() {
        var c = ActivityCoalescer()
        _ = c.submit(.celebrating, now: 0)
        let r = c.submit(.celebrating, now: 0.5)
        #expect(r == nil)
    }

    // MARK: - transient 态保持期（.failed = 0.9s）

    @Test("failed 放行后，保持期内异态 → nil")
    func failedHoldUntilBlocksOthers() {
        var c = ActivityCoalescer()
        _ = c.submit(.failed, now: 5.0)
        let r1 = c.submit(.idle, now: 5.5)
        let r2 = c.submit(.working, now: 5.89)
        #expect(r1 == nil)
        #expect(r2 == nil)
    }

    @Test("failed 保持期结束后，异态可放行")
    func failedHoldExpiredAllowsNext() {
        var c = ActivityCoalescer()
        _ = c.submit(.failed, now: 5.0)
        // holdUntil = 5.0 + 0.9 = 5.9
        let r = c.submit(.idle, now: 5.9)
        #expect(r == .idle)
    }

    // MARK: - 非 transient 态无 holdUntil

    @Test("非 transient 态（working）超 250ms 后可被替换，无额外保持")
    func nonTransientNoHold() {
        var c = ActivityCoalescer()
        _ = c.submit(.working, now: 0)
        // 超 250ms 即可切换，无 1.2s hold
        let r = c.submit(.idle, now: 0.26)
        #expect(r == .idle)
    }

    @Test("talking 不是 transient 态，250ms 后可被切换")
    func talkingIsNotTransient() {
        var c = ActivityCoalescer()
        _ = c.submit(.talking, now: 0)
        let r = c.submit(.idle, now: 0.3)
        #expect(r == .idle)
    }

    // MARK: - 连续切换序列（综合场景）

    @Test("working↔idle 快速来回在 250ms 内被全部防抖吞掉")
    func rapidToggleAllCoalesced() {
        var c = ActivityCoalescer()
        var results: [PetActivityVisual?] = []
        _ = c.submit(.idle, now: 0)
        // 模拟 transcript-tail 每 50ms 一次轮询
        results.append(c.submit(.working, now: 0.05))  // nil — 防抖
        results.append(c.submit(.idle,    now: 0.10))  // nil — 防抖
        results.append(c.submit(.working, now: 0.15))  // nil — 防抖
        results.append(c.submit(.idle,    now: 0.20))  // nil — 防抖
        #expect(results.allSatisfy { $0 == nil })
    }

    @Test("超 250ms 后切换被放行，之后重新进入防抖窗口")
    func switchAfterDwellThenReentersDebounce() {
        var c = ActivityCoalescer()
        _ = c.submit(.idle, now: 0)
        let r1 = c.submit(.working, now: 0.30)  // 放行
        let r2 = c.submit(.idle,    now: 0.35)  // nil — 距 r1 仅 50ms
        let r3 = c.submit(.idle,    now: 0.60)  // 放行 — 距 r1 过了 300ms
        #expect(r1 == .working)
        #expect(r2 == nil)
        #expect(r3 == .idle)
    }
}
