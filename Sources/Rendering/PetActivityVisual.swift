/// agent 活动映射到 pet 视觉态（petdex 官方口径：状态指示器）。
///
/// App 接线层把 `AgentSensing` 的 `AgentActivityState` + 跃迁映射成本类型，
/// 喂给 `.activityStateIndicator` 形象（如 petdex sprite）。
/// Rendering 层不直接依赖 AgentSensing，避免成环。
///
/// ## 对齐 petdex pet-states 行（spritesheet 第 0-7 行）
/// - `idle`        → idle（row 0，默认待机）
/// - `working`     → running（row 7，工具密集执行中）
/// - `reviewing`   → review（row 8，读文件/分析代码）
/// - `talking`     → waving（row 3，生成/流式输出中）
/// - `waiting`     → waiting（row 6，等待用户输入）
/// - `celebrating` → jumping（row 4，任务完成庆祝）
/// - `failed`      → failed（row 5，出错/被拒）
///
/// SpriteSheetPetRenderer（Task 3）负责按本枚举切换 spritesheet 行；
/// 其余 renderer 默认 no-op。
public enum PetActivityVisual: Sendable, Equatable {
    /// 待机，无显著 agent 活动。
    case idle
    /// 工具密集执行中（读写文件、shell 命令、搜索等）。
    case working
    /// 读取/分析代码或文档。
    case reviewing
    /// 正在向用户输出回复。
    case talking
    /// 等待用户输入。
    case waiting
    /// 任务完成，短暂庆祝。
    case celebrating
    /// 出错或工具被拒。
    case failed
}
