import Testing
@testable import RuntimeBridge
import Context

// MARK: - .ballistic 抛射回弹物理测试(纯值类型,无 GPU)
//
// 弹力球被甩出/松手后:重力 + 空气阻力积分,以窗口 AABB 撞窗口矩形外侧 + 屏幕四壁按弹性反射,
// 速度衰减到阈值且有支撑 → 落定转 .physics。碰撞几何为纯静态函数(可独立精确断言)。

private func testBounds() -> Rect { Rect(origin: Point(x: 0, y: 0), width: 1000, height: 800) }

private func ballisticInput(windows: [Rect] = []) -> PetMotionInput {
    PetMotionInput(
        deltaTime: 1.0 / 60.0,
        cursorPosition: Point(x: 0, y: 0),
        windows: windows,
        screenBounds: testBounds(),
        followingEnabled: false,
        roamingEnabled: false
    )
}

@Test("beginThrow → 进入 .ballistic")
func beginThrowEntersBallistic() {
    var c = PetMotionController()
    #expect(!c.isBallistic)
    c.beginThrow(velocity: Point(x: 200, y: 400))
    #expect(c.isBallistic)
}

@Test("抛射受重力:水平甩出一帧后 y 下降、x 推进、仍 .ballistic")
func gravityPullsDownWhileFlying() {
    var c = PetMotionController()
    c.beginThrow(velocity: Point(x: 300, y: 0))
    let prev = Point(x: 500, y: 400)
    let (next, frame) = c.resolved(previousPosition: prev, physicsCandidate: prev, input: ballisticInput())
    #expect(frame.mode == .ballistic)
    #expect(frame.position.y < prev.y)   // 重力下拉
    #expect(frame.position.x > prev.x)   // 水平初速推进
    #expect(next.isBallistic)
    #expect(frame.phase == .falling)
}

@Test("甩出初速 clamp 到 throwMaxLaunchSpeed,防穿透薄窗")
func launchSpeedClampedToMax() {
    var c = PetMotionController()
    c.beginThrow(velocity: Point(x: 99999, y: 0))
    let prev = Point(x: 0, y: 400)
    let (_, frame) = c.resolved(previousPosition: prev, physicsCandidate: prev, input: ballisticInput())
    // 一帧水平位移不超过 maxLaunchSpeed*dt(+1px 余量)
    #expect(frame.position.x - prev.x <= BallisticTuning().maxLaunchSpeed / 60.0 + 1)
}

@Test("clampInsideBounds:撞右墙 → 位置夹回 + vx 反向衰减")
func screenRightWallReflects() {
    let r = PetMotionController.clampInsideBounds(
        ox: 980, oy: 400, pw: 72, ph: 72, vx: 500, vy: 0,
        bounds: testBounds(), restitution: 0.6, friction: 0.9)
    #expect(r.ox == 1000 - 72)   // 夹回 maxX
    #expect(r.vx < 0)            // 反向
    #expect(abs(r.vx) < 500)     // 弹性衰减
}

@Test("clampInsideBounds:撞地面 → vy 反弹向上 + 衰减")
func screenFloorReflects() {
    let r = PetMotionController.clampInsideBounds(
        ox: 100, oy: -20, pw: 72, ph: 72, vx: 0, vy: -600,
        bounds: testBounds(), restitution: 0.6, friction: 0.9)
    #expect(r.oy == 0)
    #expect(r.vy > 0)
    #expect(r.vy < 600)
}

@Test("reflectOffAABB:从左侧撞窗口侧面 → 推到窗外左侧 + vx 反向")
func windowSideReflects() {
    let win = Rect(origin: Point(x: 400, y: 0), width: 200, height: 300)
    // pet [360,432]×[100,172] 与窗口 [400,600]×[0,300] 重叠,向右运动 → 最小穿透在左面。
    let r = PetMotionController.reflectOffAABB(
        ox: 360, oy: 100, pw: 72, ph: 72, vx: 400, vy: 0,
        obstacle: win, restitution: 0.6, friction: 0.9)
    #expect(r.ox == 400 - 72)   // 推到窗口左外侧
    #expect(r.vx < 0)           // 反向
    #expect(abs(r.vx) < 400)    // 衰减
}

@Test("reflectOffAABB:从上方落到窗口顶 → 站到顶边 + vy 反弹")
func windowTopReflects() {
    let win = Rect(origin: Point(x: 400, y: 200), width: 200, height: 100)  // top=300
    // pet [450,522]×[290,362] 浅穿窗口顶,向下运动 → 最小穿透在顶面。
    let r = PetMotionController.reflectOffAABB(
        ox: 450, oy: 290, pw: 72, ph: 72, vx: 0, vy: -500,
        obstacle: win, restitution: 0.6, friction: 0.9)
    #expect(r.oy == 300)        // 站到窗口顶
    #expect(r.vy > 0)           // 反弹向上
}

@Test("isSupported:贴地面 / 贴窗口顶 → true;半空 → false")
func supportDetection() {
    let b = testBounds()
    #expect(PetMotionController.isSupported(ox: 100, oy: 0, pw: 72, ph: 72, bounds: b, windows: []))
    #expect(!PetMotionController.isSupported(ox: 100, oy: 400, pw: 72, ph: 72, bounds: b, windows: []))
    let win = Rect(origin: Point(x: 80, y: 200), width: 200, height: 100)  // top=300
    #expect(PetMotionController.isSupported(ox: 100, oy: 300, pw: 72, ph: 72, bounds: b, windows: [win]))
    // 横向不重叠的窗口顶不算支撑
    #expect(!PetMotionController.isSupported(ox: 900, oy: 300, pw: 72, ph: 72, bounds: b, windows: [win]))
}

@Test("落定:低速 + 贴地 → 退出 ballistic 转 .physics")
func settleOnFloorExitsBallistic() {
    var c = PetMotionController()
    c.beginThrow(velocity: Point(x: 10, y: 0))   // 极低速
    let prev = Point(x: 100, y: 0)               // 已在地面
    let (next, frame) = c.resolved(previousPosition: prev, physicsCandidate: prev, input: ballisticInput())
    #expect(frame.mode == .physics)
    #expect(!next.isBallistic)
}

@Test("抓起打断抛射:clearForExternalControl → .physics + 速度清零(不再积分)")
func grabInterruptsBallistic() {
    var c = PetMotionController()
    c.beginThrow(velocity: Point(x: 500, y: 500))
    #expect(c.isBallistic)
    c.clearForExternalControl()
    #expect(!c.isBallistic)
    let prev = Point(x: 100, y: 400)
    let (_, frame) = c.resolved(previousPosition: prev, physicsCandidate: prev, input: ballisticInput())
    #expect(frame.mode == .physics)
    #expect(frame.position == prev)   // 不跟随不漫游 + 速度已清 → 原地静止
}

@Test("连续弹跳能量衰减:撞地后峰速逐次降低")
func bouncesLoseEnergy() {
    // 同一撞地反弹,初速越大反弹越大,但反弹恒 < 入射(restitution<1)。
    let fast = PetMotionController.clampInsideBounds(
        ox: 100, oy: -1, pw: 72, ph: 72, vx: 0, vy: -800,
        bounds: testBounds(), restitution: 0.6, friction: 0.9)
    #expect(fast.vy > 0 && fast.vy < 800)
    #expect(abs(fast.vy - 800 * 0.6) < 1)   // ≈ restitution * 入射
}
