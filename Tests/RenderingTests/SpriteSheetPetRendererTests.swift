import AppKit
import Testing
@testable import Rendering
import RuntimeBridge

@MainActor
@Suite("SpriteSheetPetRenderer")
struct SpriteSheetPetRendererTests {

    /// 画一张 `w×h` 像素的纯色 PNG 写临时文件，返回 URL。
    private func makeSheet(width: Int, height: Int) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprite-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    /// 画一张**稀疏** sheet:每行(图顶序)只填 `filled[r]` 个 cell(cols 0..<n),其余透明 —— 模拟
    /// Shimeji 转换包「每行帧数 < petdex 列数」。CGContext y-up:图顶 row r 在 context-y=H-(r+1)*fh。
    private func makeSparseSheet(cols: Int, rows: Int, frameW: Int, frameH: Int, filled: [Int]) throws -> URL {
        let W = cols * frameW, H = rows * frameH
        let ctx = try #require(CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))   // 透明底(默认清零)
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        for r in 0..<rows {
            let n = r < filled.count ? filled[r] : cols
            for c in 0..<n {
                ctx.fill(CGRect(x: c * frameW, y: H - (r + 1) * frameH, width: frameW, height: frameH))
            }
        }
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparse-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    @Test("稀疏包(每行帧数 < def 列数)→ play 裁到真实帧数,不播空 cell(根治闪烁)")
    func sparseSheetClampsToRealFrameCount() throws {
        // 模拟 Shimeji 转换包:idle(row0)1 帧、running-right(row1)3 帧。
        let url = try makeSparseSheet(cols: 8, rows: 9, frameW: 12, frameH: 13,
                                      filled: [1, 3, 3, 3, 2, 4, 2, 3, 4])
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // petdex sprite 默认 idle 行（chat 来源，idle 情绪态）
        #expect(r.currentRowForTesting == 0)
        #expect(r.currentSequenceCountForTesting == 1)  // idle def 6 帧,实 1 → 裁到 1(静止不闪)
        // 活动态切 running(row7)
        r.updateForActivity(.working)
        #expect(r.currentRowForTesting == 7)
        let runningCount = r.currentSequenceCountForTesting
        // running def 6 帧,稀疏包 row7 实 3 帧 → 裁到 3
        #expect(runningCount == 3)
    }

    @Test("满帧包(petdex 全列)→ play 不裁,保留 def 全部帧(零回归)")
    func fullSheetKeepsAllDefFrames() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)   // 全填,每行 8 帧
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // 初始 idle（chat 来源）→ idle def 6 帧全留
        #expect(r.currentSequenceCountForTesting == 6)
        // 活动态 working → running(row7)def 6 帧全留
        r.updateForActivity(.working)
        #expect(r.currentSequenceCountForTesting == 6)
    }

    @Test("合法 8×9 spritesheet → init 成功，view 有尺寸，支持招牌动作")
    func initsFromValidSheet() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)   // 96×117，≥ 8×9 网格
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(renderer.contentLayer.frame.width > 0)
        #expect(renderer.supportedSignatures.contains(.celebrate))
        #expect(renderer.supportedSignatures.contains(.greet))
        // 切情绪态不崩（驱动 row 切换 + 帧定时器）。
        renderer.updateForState(.thinking)
        renderer.updateForState(.confused)
        renderer.pauseDisplayLink()
        renderer.resumeDisplayLink()
    }

    // 注：「8×9 无 climb 行 → climbing 回退 running 镜像」和
    //     「8×10 有 climb 行 → climbing 走专用 row9」两个用例已删除。
    // 删除原因：这两个测试验证的是「运动态（climbing）驱动状态行」的行为，
    // 而该行为按设计已删除——petdex sprite 去漫步后 updateForMotion 退化为 no-op，
    // row9/climbing 专用行逻辑随 effectiveNamed() 中的 switch currentMotion 一并移除。
    // 属于对应实现行为按设计删除，非凑绿删测试。

    @Test("updateForMotion 对 petdex sprite 退化为 no-op(不再覆盖状态行)")
    func motionIsNoOpForSpriteRenderer() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // 先推入活动态 working → running(row7)
        renderer.updateForActivity(.working)
        #expect(renderer.currentRowName == "running")
        // 所有运动态调用都不改变行
        renderer.updateForMotion(.walking(.right))
        #expect(renderer.currentRowName == "running")
        renderer.updateForMotion(.walking(.left))
        #expect(renderer.currentRowName == "running")
        renderer.updateForMotion(.falling)
        #expect(renderer.currentRowName == "running")
        renderer.updateForMotion(.climbing(.right))
        #expect(renderer.currentRowName == "running")
        renderer.updateForMotion(.idle)
        #expect(renderer.currentRowName == "running")
    }

    @Test("updateForState 不经运动态直接决定行(chat 来源)")
    func updateForStateDrivesRowDirectly() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // 初始 idle
        #expect(renderer.currentRowForTesting == 0)
        // 情绪态 thinking → review(row8)
        renderer.updateForState(.thinking)
        #expect(renderer.currentRowForTesting == 8)
        // 情绪态 confused → failed(row5)
        renderer.updateForState(.confused)
        #expect(renderer.currentRowForTesting == 5)
        // 运动态不影响
        renderer.updateForMotion(.walking(.right))
        #expect(renderer.currentRowForTesting == 5)
    }

    @Test("updateForWetness 驱动水渍层不透明度(干=0,湿>0,clamp)")
    func wetnessDrivesTintOpacity() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(renderer.wetTintOpacityForTesting == 0)        // 初始干
        renderer.updateForWetness(1.0)
        #expect(renderer.wetTintOpacityForTesting > 0)         // 湿 → tint 上来
        let full = renderer.wetTintOpacityForTesting
        renderer.updateForWetness(0.5)
        #expect(renderer.wetTintOpacityForTesting < full)      // 半湿 < 全湿
        #expect(renderer.wetTintOpacityForTesting > 0)
        renderer.updateForWetness(0)
        #expect(renderer.wetTintOpacityForTesting == 0)        // 回干
        renderer.updateForWetness(5.0)                          // 越界 clamp 到 1
        #expect(renderer.wetTintOpacityForTesting == full)
    }

    @Test("currentFrameAlphaMask 提取当前帧 alpha 轮廓(非空 + aspect-fit letterbox + 缓存)")
    func alphaMaskExtractsCurrentFrame() throws {
        let url = try makeSheet(width: 8 * 24, height: 9 * 26)   // 帧 24×26，纯不透明 teal
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // host view 72×72，cellSize=1 → mask 72×72。
        let m = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 128))
        #expect(m.width == 72 && m.height == 72)
        #expect(m.mask.count == 72 * 72)
        let opaque = m.mask.filter { $0 >= 128 }.count
        // 帧 24×26 aspect-fit 进 72×72 → 填满高度、宽度居中(留左右 letterbox)。
        #expect(opaque > 1000)                  // 真画出轮廓(非全透)
        #expect(opaque < 72 * 72)               // 有 letterbox(非铺满整框)
        // 缓存:同帧再取应等值(帧未变)。
        let m2 = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 128))
        #expect(m2 == m)
        // maxDim clamp:小 maxDim → mask 单边受限。
        let small = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 16))
        #expect(small.width == 16 && small.height == 16)
    }

    @Test("尺寸不足 8×9 → init 返回 nil（Shell 回退 placeholder）")
    func failsOnTinySheet() throws {
        let url = try makeSheet(width: 4, height: 4)
        #expect(SpriteSheetPetRenderer(spritesheetURL: url) == nil)
    }

    @Test("不存在的文件 → init 返回 nil")
    func failsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).png")
        #expect(SpriteSheetPetRenderer(spritesheetURL: url) == nil)
    }

    @Test("CodexSpritePackLoader.discover 不崩，返回的 id 都带 codex: 前缀")
    func discoverDoesNotCrash() {
        let entries = CodexSpritePackLoader.discover()   // 读真实 ~/.codex/pets/，可能空
        for e in entries {
            #expect(e.identity.id.hasPrefix("codex:"))
        }
    }

    // MARK: - 活动态驱动状态行（Task 3 新增）

    @Test("updateForActivity 7 种活动态各映射正确 petdex 状态行")
    func activityMapsToCorrectRows() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        r.updateForActivity(.working)
        #expect(r.currentRowName == "running")      // row7
        r.updateForActivity(.reviewing)
        #expect(r.currentRowName == "review")       // row8
        r.updateForActivity(.talking)
        #expect(r.currentRowName == "waving")       // row3
        r.updateForActivity(.waiting)
        #expect(r.currentRowName == "waiting")      // row6
        r.updateForActivity(.celebrating)
        #expect(r.currentRowName == "jumping")      // row4
        r.updateForActivity(.failed)
        #expect(r.currentRowName == "failed")       // row5
        r.updateForActivity(.idle)
        #expect(r.currentRowName == "idle")         // row0
    }

    @Test("most-recent-wins: activity 后再 updateForState → chat 来源赢")
    func mostRecentWinsChatAfterActivity() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        r.updateForActivity(.working)               // activity 来源 → running(row7)
        #expect(r.currentRowName == "running")
        r.updateForState(.thinking)                 // chat 来源最新 → review(row8)
        #expect(r.currentRowName == "review")
    }

    @Test("most-recent-wins: updateForState 后再 updateForActivity → activity 来源赢")
    func mostRecentWinsActivityAfterChat() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        r.updateForState(.thinking)                 // chat 来源 → review(row8)
        #expect(r.currentRowName == "review")
        r.updateForActivity(.waiting)               // activity 来源最新 → waiting(row6)
        #expect(r.currentRowName == "waiting")
    }

    @Test("初始无活动推入时行由聊天态决定(默认 chat 来源)")
    func defaultsToChat() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // 无任何 updateForActivity → chat 来源，默认情绪 idle = row0
        #expect(r.currentRowName == "idle")
        r.updateForState(.confused)
        #expect(r.currentRowName == "failed")       // confused → failed(row5)
    }

    @Test("driveModel 声明为 activityStateIndicator")
    func driveModelIsActivityStateIndicator() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(r.driveModel == .activityStateIndicator)
    }

    /// 离屏渲染验证：把 renderer 的 layer 画进 bitmap，断言真有非透明像素落上去。
    /// 这是 overlay 截图抓不到（Metal/屏保）时的视觉验收手段，也防"加载成功但没画出来"。
    @Test("sprite 真画出像素（离屏 layer.render 非空）")
    func drawsNonBlankFrame() throws {
        let url = try makeSheet(width: 8 * 24, height: 9 * 26)   // 帧 24×26，纯 teal
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.contentLayer.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        let layer = renderer.contentLayer

        let w = 72, h = 72
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        layer.render(in: ctx)

        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var opaque = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where pixels[i + 3] > 0 { opaque += 1 }
        #expect(opaque > 0, "sprite layer 渲染出全透明 → 没画出帧")
    }

    @Test("空闲小动作:supportedSignatures 含 signatureIdle + trigger 不崩")
    func idleFidgetSignatureSupported() throws {
        let url = try makeSheet(width: 96, height: 117)          // 8×9 标准包
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(r.supportedSignatures.contains(.signatureIdle))  // 渲染器声明支持空闲小动作(PetAgent 个性层)
        r.trigger(.signatureIdle)                                // 触发不崩(复用 jumping 行一次性小跳)
    }
}
