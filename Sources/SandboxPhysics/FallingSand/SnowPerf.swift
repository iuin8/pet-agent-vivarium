import Foundation
import QuartzCore
import Metal

/// 雪物理 GPU 计时自诊断 —— `PETAGENT_DEBUG_SNOWPERF=1` 启用,每 60 帧往 stderr 打三相
/// (integrate / land / step)的帧均:
///   - `wall` = 该相占主线程的 wall-clock(encode + commit + waitUntilCompleted),即主线程被占多久;
///   - `gpu`  = 该相 GPU 实际执行时长(`commandBuffer.gpuEndTime - gpuStartTime`);因每相同步 wait,
///              主线程**整段 gpu 时间都在 `waitUntilCompleted` 里干等** → gpu ≈「可被批量/异步消除的等待」;
///   - `cpu`  = wall - gpu ≈ encode + commit 的 CPU 开销(批量化**消不掉**这部分)。
///
/// 判读(§5.15 先量再改):若 gpu 是 wall 大头 → integrate/land/step 合一 commandBuffer + 单次 wait /
/// GPU-side 依赖**值得做**(主线程不再 3× 干等);若 cpu 大头 → 批量化收益有限,真瓶颈在 encode/参数。
/// 范式照 `FramePerf`(项目惯例:自写代码级计时仪,不靠 GUI Instruments)。env 未设则零成本。
public enum SnowPerf {
    public static let isEnabled = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SNOWPERF"] == "1"

    private static var wallMs: [String: Double] = [:]
    private static var gpuMs: [String: Double] = [:]
    private static var frames = 0
    private static let order = ["integrate", "land", "step"]

    /// 在某相的 commit+wait 之后调:`startTime` 为该相入口的 `CACurrentMediaTime()`,`cmd` 取 GPU 时间戳。
    public static func record(_ phase: String, startTime: Double, _ cmd: MTLCommandBuffer) {
        guard isEnabled else { return }
        wallMs[phase, default: 0] += (CACurrentMediaTime() - startTime) * 1000.0
        gpuMs[phase, default: 0] += max(0, (cmd.gpuEndTime - cmd.gpuStartTime)) * 1000.0
    }

    /// 每帧(driver.tick)末调,满 60 帧打印一行帧均并清零。
    public static func frameEnd() {
        guard isEnabled else { return }
        frames += 1
        guard frames % 60 == 0 else { return }
        let n = 60.0
        let parts = order.map { p -> String in
            let w = wallMs[p, default: 0] / n, g = gpuMs[p, default: 0] / n
            return String(format: "%@ wall=%.2f gpu=%.2f cpu=%.2f", p, w, g, max(0, w - g))
        }
        let total = order.reduce(0.0) { $0 + wallMs[$1, default: 0] } / n
        fputs("[SnowPerf/帧均ms] total=\(String(format: "%.2f", total)) | " + parts.joined(separator: " | ") + "\n", stderr)
        wallMs.removeAll(); gpuMs.removeAll()
    }
}
