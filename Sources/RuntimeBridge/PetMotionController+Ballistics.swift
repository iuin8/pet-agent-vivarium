import Context

/// `.ballistic` 抛射回弹的**纯碰撞几何** —— pet 以窗口 AABB 撞窗口矩形外侧 + 屏幕四壁按
/// 弹性系数反射(与本仓窗口矩形碰撞一致):最小穿透轴出方向 + 该轴速度反射 + 另一轴切向摩擦。
///
/// 坐标系:bottom-origin y-up。pet AABB = `(origin=(ox,oy), pw, ph)`。`Point` 不可变 →
/// 几何全用 Double 标量算。状态变更(重力积分 / 落定切 mode)在主文件 `integrateBallistic`。
extension PetMotionController {

    /// pet AABB 撞窗口障碍**外侧**:重叠则沿最小穿透轴推出 + 该轴速度反射(仅当朝障碍运动)+ 另一轴切向摩擦。
    static func reflectOffAABB(
        ox: Double, oy: Double, pw: Double, ph: Double, vx: Double, vy: Double,
        obstacle w: Rect, restitution e: Double, friction: Double
    ) -> (ox: Double, oy: Double, vx: Double, vy: Double) {
        let pMinX = ox, pMaxX = ox + pw
        let pMinY = oy, pMaxY = oy + ph
        let wMinX = w.origin.x, wMaxX = w.origin.x + w.width
        let wMinY = w.origin.y, wMaxY = w.origin.y + w.height
        // 无重叠 → 不碰。
        guard pMaxX > wMinX, pMinX < wMaxX, pMaxY > wMinY, pMinY < wMaxY else {
            return (ox, oy, vx, vy)
        }
        // 四个方向的穿透深度,取最小者出方向。
        let penLeft = pMaxX - wMinX     // 把 pet 推到障碍左侧(-x)
        let penRight = wMaxX - pMinX    // 推到右侧(+x)
        let penDown = pMaxY - wMinY     // 推到下方(-y)
        let penUp = wMaxY - pMinY       // 推到上方(+y),= 站到障碍顶
        let minPen = min(penLeft, penRight, penDown, penUp)
        var nox = ox, noy = oy, nvx = vx, nvy = vy
        // 切向摩擦收进各自速度闸内:仅真正发生反射(朝该面运动)时才施摩擦 —— 否则同帧串行
        // 反射多个堆叠/重叠窗口会让「只推位置未反射」的分支也反复乘 friction,复利累积失真。
        if minPen == penUp {
            noy = wMaxY                 // 站到窗口顶边
            if nvy < 0 { nvy = -nvy * e; nvx *= friction }
        } else if minPen == penDown {
            noy = wMinY - ph            // 顶到窗口底
            if nvy > 0 { nvy = -nvy * e; nvx *= friction }
        } else if minPen == penLeft {
            nox = wMinX - pw            // 撞左面(向右运动)→ 弹回
            if nvx > 0 { nvx = -nvx * e; nvy *= friction }
        } else {
            nox = wMaxX                 // 撞右面(向左运动)→ 弹回
            if nvx < 0 { nvx = -nvx * e; nvy *= friction }
        }
        return (nox, noy, nvx, nvy)
    }

    /// pet AABB 夹在屏幕可视范围内,撞四壁反射(仅当朝墙运动)+ 沿墙切向摩擦。
    static func clampInsideBounds(
        ox: Double, oy: Double, pw: Double, ph: Double, vx: Double, vy: Double,
        bounds: Rect, restitution e: Double, friction: Double
    ) -> (ox: Double, oy: Double, vx: Double, vy: Double) {
        let minX = bounds.origin.x
        let maxX = bounds.origin.x + bounds.width - pw
        let minY = bounds.origin.y
        let maxY = bounds.origin.y + bounds.height - ph
        var nox = ox, noy = oy, nvx = vx, nvy = vy
        if nox < minX { nox = minX; if nvx < 0 { nvx = -nvx * e; nvy *= friction } }
        if nox > maxX { nox = maxX; if nvx > 0 { nvx = -nvx * e; nvy *= friction } }
        if noy < minY { noy = minY; if nvy < 0 { nvy = -nvy * e; nvx *= friction } }
        if noy > maxY { noy = maxY; if nvy > 0 { nvy = -nvy * e; nvx *= friction } }
        return (nox, noy, nvx, nvy)
    }

    /// 是否有支撑:pet 底贴地面,或贴某窗口顶边且与其横向重叠。
    static func isSupported(ox: Double, oy: Double, pw: Double, ph: Double, bounds: Rect, windows: [Rect]) -> Bool {
        if oy <= bounds.origin.y + groundSnapEpsilon { return true }
        for w in windows {
            let top = w.origin.y + w.height
            if abs(oy - top) <= groundSnapEpsilon + 1.5,
               ox + pw > w.origin.x, ox < w.origin.x + w.width {
                return true
            }
        }
        return false
    }
}
