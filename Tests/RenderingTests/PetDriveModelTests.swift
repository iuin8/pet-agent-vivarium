import AppKit
import Testing
@testable import Rendering

// MARK: - PetDriveModel 测试
//
// 验证：
// 1. 未声明 driveModel 的 renderer 默认 .proceduralMotion
// 2. SpriteSheetPetRenderer 声明 .activityStateIndicator
// 3. drivesOwnWindowPosition 由 driveModel 派生（.autonomousEngine → true，其余 → false）

@MainActor
@Suite("PetDriveModel")
struct PetDriveModelTests {

    // MARK: - 夹具

    /// 画一张 8×9 spritesheet PNG 写临时文件，供 SpriteSheetPetRenderer 构造。
    private func makeSpriteFixture() throws -> URL {
        let cols = 8, rows = 9, fw = 12, fh = 13
        let W = cols * fw, H = rows * fh
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivemodel-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    // MARK: - 枚举完整性

    @Test("PetDriveModel 四个 case 可比较相等")
    func enumCasesAreEquatable() {
        #expect(PetDriveModel.autonomousEngine == .autonomousEngine)
        #expect(PetDriveModel.proceduralMotion == .proceduralMotion)
        #expect(PetDriveModel.activityStateIndicator == .activityStateIndicator)
        #expect(PetDriveModel.selfAnimating == .selfAnimating)
        #expect(PetDriveModel.autonomousEngine != .proceduralMotion)
    }

    // MARK: - 默认值

    @Test("OrbMetalRenderer 默认 driveModel 为 proceduralMotion")
    func orbDefaultDriveModel() {
        guard let renderer = OrbMetalRenderer() else { return }   // 无 GPU 时跳过
        #expect(renderer.driveModel == .proceduralMotion)
    }

    // MARK: - SpriteSheetPetRenderer

    @Test("SpriteSheetPetRenderer 声明 activityStateIndicator")
    func spriteDriveModel() throws {
        let url = try makeSpriteFixture()
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(r.driveModel == .activityStateIndicator)
    }

    // MARK: - drivesOwnWindowPosition 由 driveModel 派生

    @Test("OrbMetalRenderer.drivesOwnWindowPosition 为 false（proceduralMotion 派生）")
    func orbDrivesOwnWindowPositionFalse() {
        guard let renderer = OrbMetalRenderer() else { return }
        #expect(renderer.drivesOwnWindowPosition == false)
    }

    @Test("SpriteSheetPetRenderer.drivesOwnWindowPosition 为 false（activityStateIndicator 不自管窗口）")
    func spriteDrivesOwnWindowPositionFalse() throws {
        // 派生公式：仅 driveModel == .autonomousEngine 为 true。activityStateIndicator 位置由帧循环
        // holdPetPosition 固定、拖拽走 host adapter，不自管窗口 → false。
        let url = try makeSpriteFixture()
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(r.drivesOwnWindowPosition == false)
    }

    // MARK: - drivesOwnWindowPosition 派生契约(用 mock 锁全部四态)

    /// 最小 renderer，仅用来按 driveModel 验证 drivesOwnWindowPosition 派生。
    final class DriveModelRenderer: PetRenderer {
        let contentLayer: CALayer = CALayer()
        private let model: PetDriveModel
        init(_ model: PetDriveModel) { self.model = model }
        var driveModel: PetDriveModel { model }
        func updateForState(_ state: PetEmotionState) {}
    }

    @Test("autonomousEngine → drivesOwnWindowPosition true（仅引擎自管窗口）")
    func autonomousEngineDrivesOwnWindowPositionTrue() {
        #expect(DriveModelRenderer(.autonomousEngine).drivesOwnWindowPosition == true)
    }

    @Test("selfAnimating → drivesOwnWindowPosition false（Live2D 无引擎指针,拖拽走 host adapter）")
    func selfAnimatingDrivesOwnWindowPositionFalse() {
        // 回归守卫:曾误派生为 true → Live2D 拖拽事件被路由进 no-op handlePointerDown → 拖不动。
        #expect(DriveModelRenderer(.selfAnimating).drivesOwnWindowPosition == false)
    }

    @Test("activityStateIndicator / proceduralMotion → drivesOwnWindowPosition false")
    func otherDriveModelsDrivesOwnWindowPositionFalse() {
        #expect(DriveModelRenderer(.activityStateIndicator).drivesOwnWindowPosition == false)
        #expect(DriveModelRenderer(.proceduralMotion).drivesOwnWindowPosition == false)
    }
}
