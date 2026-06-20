import AppKit
import Testing
@testable import Rendering

// MARK: - PetActivityVisual 测试
//
// 验证：
// 1. 枚举 7 态（idle/working/reviewing/talking/waiting/celebrating/failed）可比较相等
// 2. updateForActivity 默认 no-op 不崩（任意实现都能安全接收推入）

@MainActor
@Suite("PetActivityVisual")
struct PetActivityVisualTests {

    // MARK: - 枚举完整性

    @Test("PetActivityVisual 包含全部 7 个 case")
    func allCasesPresent() {
        // 逐一枚举，确保没有遗漏 case
        let all: [PetActivityVisual] = [
            .idle, .working, .reviewing, .talking, .waiting, .celebrating, .failed,
        ]
        #expect(all.count == 7)
    }

    @Test("PetActivityVisual 各 case 可比较相等")
    func casesAreEquatable() {
        #expect(PetActivityVisual.idle == .idle)
        #expect(PetActivityVisual.working == .working)
        #expect(PetActivityVisual.reviewing == .reviewing)
        #expect(PetActivityVisual.talking == .talking)
        #expect(PetActivityVisual.waiting == .waiting)
        #expect(PetActivityVisual.celebrating == .celebrating)
        #expect(PetActivityVisual.failed == .failed)
        // 不同 case 不相等
        #expect(PetActivityVisual.idle != .working)
        #expect(PetActivityVisual.failed != .celebrating)
    }

    // MARK: - updateForActivity 默认 no-op

    @Test("OrbMetalRenderer.updateForActivity 默认 no-op 不崩")
    func orbUpdateForActivityIsNoOp() {
        guard let renderer = OrbMetalRenderer() else { return }   // 无 GPU 时跳过
        // 全部 7 态推入，不崩即通过
        renderer.updateForActivity(.idle)
        renderer.updateForActivity(.working)
        renderer.updateForActivity(.reviewing)
        renderer.updateForActivity(.talking)
        renderer.updateForActivity(.waiting)
        renderer.updateForActivity(.celebrating)
        renderer.updateForActivity(.failed)
    }

    @Test("SpriteSheetPetRenderer.updateForActivity 默认 no-op 不崩")
    func spriteUpdateForActivityIsNoOp() throws {
        let url = try makeSpriteFixture()
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // 全部 7 态推入，不崩即通过（Task 3 才实现实际映射）
        renderer.updateForActivity(.idle)
        renderer.updateForActivity(.working)
        renderer.updateForActivity(.reviewing)
        renderer.updateForActivity(.talking)
        renderer.updateForActivity(.waiting)
        renderer.updateForActivity(.celebrating)
        renderer.updateForActivity(.failed)
    }

    // MARK: - Sendable + Equatable

    @Test("PetActivityVisual 符合 Sendable 和 Equatable（跨 actor 传递安全）")
    func conformances() {
        // 编译期已保证；运行时只需不崩
        let v: PetActivityVisual = .working
        let _: any Sendable = v
        let _: any Equatable = v
    }

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
            .appendingPathComponent("activityvisual-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}
