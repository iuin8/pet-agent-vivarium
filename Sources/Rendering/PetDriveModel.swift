/// pet 形象的运动驱动范式 —— 帧循环据此分发，取代 `as? ShimejiPetRenderer` 二元 cast。
/// 每格式按各自官方约定驱动，不交叉转换。
/// 详见 docs/pet-per-format-driver-design.md。
public enum PetDriveModel: Sendable, Equatable {
    /// Shimeji：引擎自驱位置 + 行为图，`PetMotionController` 全部让位。
    case autonomousEngine
    /// Orb / Slime：`PetMotionController` 仲裁位置 + squash 形变，默认范式。
    case proceduralMotion
    /// petdex sprite：agent 活动 → 状态行，位置由帧循环固定（不走漫步/爬墙）。
    case activityStateIndicator
    /// Live2D：Cubism SDK 自驱姿态/物理，位置固定，漫步为可选 opt-in（默认关）。
    case selfAnimating
}
