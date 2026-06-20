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

    @Test("SpriteSheetPetRenderer.drivesOwnWindowPosition 为 false（activityStateIndicator 当前不自管窗口）")
    func spriteDrivesOwnWindowPositionFalse() throws {
        // Task 5 里 spec Step 5 说：activityStateIndicator → 位置固定但不走 drivesOwnWindowPosition true
        // drivesOwnWindowPosition 派生公式：driveModel == .autonomousEngine || .selfAnimating
        // activityStateIndicator 位置固定由帧循环 holdPetPosition 实现，不需要 renderer 自管窗口
        let url = try makeSpriteFixture()
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(r.drivesOwnWindowPosition == false)
    }
}
