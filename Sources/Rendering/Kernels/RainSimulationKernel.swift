/// MSL 源:`rain_simulation` 计算 kernel — 每帧给每颗粒子更新 position +
/// velocity + lifetime,落地 (y < 0) 时 respawn 顶部 或 spawn 2-4 颗
/// splash 子粒子横向扩散。
///
/// 设计原则:
/// 1. 单一 kernel,无堆积、无温度场、无 SDF。雨刻意极简。
/// 2. 主雨 vs splash 复用同一 `GpuRainParticle` struct,用 lifetime + velocity.y
///    符号区分:
///    - 主雨:lifetime ∈ (0, 1.0],velocity.y < 0(下落)
///    - splash:lifetime ∈ (0, 0.15],velocity.y > 0(横向反弹,带轻微上升)
/// 3. 落地 (next_y < 0) **或者跨越 collision rect 顶部**:
///    - 若当前是主雨(velocity.y < 0):
///      把当前 slot 转成 splash(lifetime = 0.1, velocity = (±横向, +30..100))。
///    - 若当前是 splash(velocity.y > 0)且寿命到 → 重生为主雨。
/// 4. wind:主雨 X drift = `windX / 3 + sin(t·0.04 + seed) · 0.3`(雪
///    的 1/3 — 雨重,受 wind 弱)。
/// 5. **任务 A 新增**:雨打窗口顶 / 雪堆顶 splash。kernel 拿到 collision
///    rect 数组,对每颗下落中的主雨同时判定 `next_y < 0`(地面)和
///    `prev_y > rect_top && next_y <= rect_top && x ∈ [minX, maxX]`
///    (任一矩形顶 — 窗口、雪堆 placeholder 等)→ 触发同款 splash。
///    rect 内层循环 N ≤ 64,典型 8-30,kernel 内 for-loop 完全 OK。
///
/// 依赖 `RainKernelShared.source` 中的 `GpuRainParticle` struct +
/// `RainSimulationUniforms` struct + `GpuRainCollisionRect` struct + hash helper。
enum RainSimulationKernel {
    static let source: String = """
// --------------------------------------------------------------------
// rain_splash_trigger: 共享 splash 触发(把当前 slot 重写成 splash 子粒子)
// 任务 A 新增 — 主雨落地 / 跨越 rect 顶 两条路径共用。
// `splash_x` / `splash_y`:splash 起点坐标(地面 = next_y<0 时是 next_x,
// rect 顶 = 命中的 rect 顶部 +0.5 略高)。
// --------------------------------------------------------------------
static inline GpuRainParticle rain_make_splash(
    GpuRainParticle p, uint frame_index,
    float splash_x, float splash_y
) {
    uint splash_seed = (p.seed ^ frame_index) * 0x85EBCA6Bu;
    float r1 = rain_hash_unit(splash_seed);
    float r2 = rain_hash_unit(splash_seed * 0x27D4EB2Du);
    p.position.x = splash_x;
    p.position.y = splash_y;
    // splash 横向速度:符号随机,数值 ±120 px/s — 跟落地 splash 同款。
    p.velocity.x = (r1 - 0.5) * 240.0;
    // 2026-05-27: velocity.y 40-100 → 10-30 修"splash 像弹跳"视觉 bug。
    // 真雨 splash 是贴地横向扩散水花,不是大力反弹。10-30 让 splash 几乎
    // 贴地飞 0.1s 后消失,看起来像水溅起来扩散而非弹球。
    p.velocity.y = 10.0 + r2 * 20.0;
    p.lifetime = 0.1;
    return p;
}

// --------------------------------------------------------------------
// rain_try_deposit_water_cell: 任务 #64 共享 pile water cell 写入助手。
//
// 给定 (世界x, deposit基准y),向上找第一个空 cell,CAS 写入
//   payload = 3u = pile_payload_encode(1, 1, 0, 0)
//     = bit 0 (occupied) | bit 1 (water) | bit 2 (vapor=0) | bits 3..31 (age=0)
// 位布局来源:Sources/Rendering/PileCellPayloadV2.swift +
//             Sources/Rendering/Kernels/SnowKernelShared.swift
//
// 成功返回 true(调用方负责 respawn 粒子到顶部);
// 失败(8 row 内都满 / 越界 / 没绑 buffer)返回 false → 调用方走 splash。
//
// 同时返回 (out) attempt_row 给调用方记录(测试可见性 / 调试),但当前
// 调用方都不读它,留作扩展占位。
// --------------------------------------------------------------------
static inline bool rain_try_deposit_water_cell(
    device atomic_uint* pile_cells,
    constant RainSimulationUniforms& u,
    float deposit_x,
    float deposit_y
) {
    if (u.has_pile_buffer == 0u) { return false; }
    if (u.pile_cell_grid_size.x == 0u || u.pile_cell_grid_size.y == 0u) { return false; }
    if (u.pile_cell_size.x <= 0.0 || u.pile_cell_size.y <= 0.0) { return false; }
    if (deposit_x < 0.0) { return false; }

    uint cx = uint(deposit_x / u.pile_cell_size.x);
    if (cx >= u.pile_cell_grid_size.x) { return false; }

    // base_row 是 deposit_y 对应的 cell 行;clamp 到 [0, gridH-1]。
    // deposit_y < 0(地面)按 row 0 起步;否则从 rect_top 起步往上爬。
    uint base_row = deposit_y > 0.0 ? uint(deposit_y / u.pile_cell_size.y) : 0u;
    if (base_row >= u.pile_cell_grid_size.y) { return false; }

    // 8 row 内找空 cell。常态 puddle 厚度 ≤ 8 cells 完全够;堆满则
    // fallback splash 不消失,视觉上等同 rect 顶有水滴溅起。
    const uint max_climb = 8u;
    uint row = base_row;
    while (row < u.pile_cell_grid_size.y && (row - base_row) < max_climb) {
        uint cell_idx = row * u.pile_cell_grid_size.x + cx;
        uint expected = 0u;
        // payload = 3u = (occupied=1) | (water=1 << 1) — 见上方位布局注释。
        if (atomic_compare_exchange_weak_explicit(
                &pile_cells[cell_idx],
                &expected,
                3u,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return true;
        }
        row += 1u;
    }
    return false;
}

// --------------------------------------------------------------------
// rain_respawn_top: 任务 #64 抽出 — 雨成功 deposit 后把粒子重置到顶部
// 重新下落,跟原 lifetime≤0 respawn 分支一致。复用避免代码漂移。
// --------------------------------------------------------------------
static inline GpuRainParticle rain_respawn_top(
    GpuRainParticle p,
    constant RainSimulationUniforms& u
) {
    uint seed = p.seed ^ (u.frame_index * 0x9E3779B1u);
    float r1 = rain_hash_unit(seed);
    float r2 = rain_hash_unit(seed * 0x27D4EB2Du);
    p.position.x = r1 * u.world_size.x;
    p.position.y = u.world_size.y + r2 * 80.0;
    p.velocity.x = (u.wind_x / 3.0) + (r2 - 0.5) * 40.0;
    p.velocity.y = -(180.0 + r1 * 90.0);
    p.lifetime = 0.6 + r2 * 0.4;
    return p;
}

// --------------------------------------------------------------------
// rain_simulation: 主雨 + splash 子粒子 一锅炖
// --------------------------------------------------------------------
kernel void rain_simulation(
    device GpuRainParticle* particles                    [[buffer(0)]],
    constant RainSimulationUniforms& u                   [[buffer(1)]],
    device const GpuRainCollisionRect* collision_rects   [[buffer(2)]],
    device atomic_uint* pile_cells                       [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particle_count) { return; }
    GpuRainParticle p = particles[id];

    // splash 子粒子识别 — velocity.y > 0 (向上反弹) 是 splash 特征。
    // 主雨永远 velocity.y < 0 (下落)。
    bool is_splash = (p.velocity.y > 0.0);

    // 寿命衰减。splash 衰减比主雨快得多(splash 0.1s 全寿命,主雨 ~0.6s)。
    float lifetime_drain = is_splash ? (u.dt * 10.0) : (u.dt * 1.4);
    p.lifetime -= lifetime_drain;

    if (is_splash) {
        // splash:横向飞,带很小重力,寿命到 → 重生为主雨。
        p.velocity.y -= u.gravity * 0.5 * u.dt;
        p.position.x += p.velocity.x * u.dt;
        p.position.y += p.velocity.y * u.dt;
        if (p.lifetime <= 0.0) {
            // 重生为主雨。位置随机化到顶部,velocity 重置为下落。
            uint seed = p.seed ^ (u.frame_index * 0x9E3779B1u);
            float r1 = rain_hash_unit(seed);
            float r2 = rain_hash_unit(seed * 0x27D4EB2Du);
            p.position.x = r1 * u.world_size.x;
            p.position.y = u.world_size.y + r2 * 80.0;  // 顶部上方 0..80 抖动
            // 初速度:主雨 180-270 px/s 下落 + 跟 windX 同向 0..40 横移
            p.velocity.x = (u.wind_x / 3.0) + (r2 - 0.5) * 40.0;
            p.velocity.y = -(180.0 + r1 * 90.0);
            p.lifetime = 0.6 + r2 * 0.4;
        }
        particles[id] = p;
        return;
    }

    // -------- 主雨路径 --------
    // wind drift (横向):windX/3 衰减 + sin(seed phase) 微振 0.3 px。
    // 雪 baseline 是 sin × 0.3 系数,雨 reuse 同思路但 wind 系数 /3。
    float phase = u.frame_index * 0.04 + float(p.seed) * 0.0001;
    float drift = (u.wind_x / 3.0) + sin(phase) * 0.3;

    // 重力 — 雪默认 120 px/s², 雨默认 1200。雨落得快是核心视觉。
    p.velocity.y -= u.gravity * u.dt;
    // wind 朝目标速度收敛,而不是直接覆盖(更自然)。
    float wind_target = u.wind_x / 3.0;
    p.velocity.x += (wind_target - p.velocity.x) * 2.0 * u.dt;
    p.velocity.x += drift * u.dt;  // sin 微振叠加

    float prev_y = p.position.y;
    float next_x = p.position.x + p.velocity.x * u.dt;
    float next_y = p.position.y + p.velocity.y * u.dt;

    // 左右出界 wrap (主雨 X 边界 wrap,跟雪一样无限循环)。
    if (u.world_size.x > 0.0) {
        float wrapped = fmod(next_x + u.world_size.x, u.world_size.x);
        next_x = wrapped < 0.0 ? wrapped + u.world_size.x : wrapped;
    }

    // -------- 任务 A:collision rect 跨顶判定 --------
    // 主雨从 prev_y 落到 next_y(prev_y > next_y),如果中途跨过任何
    // 一个 rect 的 max_y 顶线、且 x 在 rect 横向范围内,就触发 splash。
    //
    // N <= 64,kernel 内层 for-loop。最近最高的 rect 顶优先(类比雪
    // `settle_on_rects` 取 best_top 的处理),避免被低 rect 抢先 splash。
    if (u.collision_rect_count > 0u) {
        float best_top = -1e9;
        bool found = false;
        for (uint i = 0u; i < u.collision_rect_count; ++i) {
            GpuRainCollisionRect r = collision_rects[i];
            // x 范围用 next_x(下落后的 x)— 跟雪的 settle_on_rects 一致。
            if (next_x < r.min_x || next_x > r.max_x) { continue; }
            float rect_top = r.max_y;
            // 主雨"跨越"这个 rect 顶:prev_y >= rect_top 且 next_y < rect_top。
            if (prev_y >= rect_top && next_y < rect_top) {
                if (!found || rect_top > best_top) {
                    best_top = rect_top;
                    found = true;
                }
            }
        }
        if (found) {
            // 任务 #64:先尝试写入 pile water cell(rect 顶 = base_row 起步,
            // 向上找空 cell 累积成 puddle)。成功 → respawn 顶部继续下雨;
            // 失败(没绑 pile buffer / 8 row 内都满)→ fallback 到原 splash。
            if (rain_try_deposit_water_cell(pile_cells, u, next_x, best_top)) {
                p = rain_respawn_top(p, u);
                particles[id] = p;
                return;
            }
            // splash 起点:rect 顶 + 0.5 略高,横向继承当前 next_x。
            p = rain_make_splash(p, u.frame_index, next_x, best_top + 0.5);
            particles[id] = p;
            return;
        }
    }

    // 落地检测 — next_y < 0(屏幕底部地面)。
    if (next_y < 0.0) {
        // 任务 #64:地面同款 — 先尝试写 row 0 起步的 water cell。
        // 桌面有 menu bar / dock,地面落雨现实里也应该积水(雨打在桌面壁纸上)。
        if (rain_try_deposit_water_cell(pile_cells, u, next_x, 0.0)) {
            p = rain_respawn_top(p, u);
            particles[id] = p;
            return;
        }
        p = rain_make_splash(p, u.frame_index, next_x, 0.5);
        particles[id] = p;
        return;
    }

    // 寿命到 → respawn 主雨顶部(防止粒子卡死、给视觉刷新感)。
    if (p.lifetime <= 0.0) {
        uint seed = p.seed ^ (u.frame_index * 0x9E3779B1u);
        float r1 = rain_hash_unit(seed);
        float r2 = rain_hash_unit(seed * 0x27D4EB2Du);
        p.position.x = r1 * u.world_size.x;
        p.position.y = u.world_size.y + r2 * 80.0;
        p.velocity.x = (u.wind_x / 3.0) + (r2 - 0.5) * 40.0;
        p.velocity.y = -(180.0 + r1 * 90.0);
        p.lifetime = 0.6 + r2 * 0.4;
        particles[id] = p;
        return;
    }

    // 正常推进
    p.position.x = next_x;
    p.position.y = next_y;
    particles[id] = p;
}
"""
}

/// MSL 共享 preamble — `GpuRainParticle` struct + uniforms struct +
/// `GpuRainCollisionRect` struct + `rain_hash_unit` helper。
enum RainKernelShared {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct GpuRainParticle {
    float2 position;
    float2 velocity;
    float  lifetime;
    uint   seed;
};

struct RainSimulationUniforms {
    float dt;
    float2 world_size;
    uint  frame_index;
    uint  particle_count;
    float wind_x;
    float gravity;
    uint  collision_rect_count;
    // 任务 #64:接 snow pile water cell 体系。
    // pile_cell_grid_size 是 snow simulation 的 (cellGridW, cellGridH);
    // pile_cell_size 是每个 cell 在世界坐标的尺寸 (px),典型 (4, 4)。
    // has_pile_buffer == 1 时 kernel 优先把雨落到 rect top 或地面 → atomic
    // CAS 写 pile cell payload = 3u (occupied=1, water=1, vapor=0, age=0),
    // 失败时回退到 rain_make_splash。0 时直接走旧 splash 路径。
    uint2 pile_cell_grid_size;
    float2 pile_cell_size;
    uint  has_pile_buffer;
};

/// 任务 A:雨打窗口 collision rect 的 MSL struct。
/// stride 16 bytes,字段对齐 Swift 端 `RainCollisionRect`。
/// 4 个 float = (min_x, min_y, max_x, max_y),屏幕坐标 bottom-origin。
struct GpuRainCollisionRect {
    float min_x;
    float min_y;
    float max_x;
    float max_y;
};

/// 32-bit integer hash → [0, 1) float。跟 SnowKernelShared.hash_unit
/// 同款逻辑(独立命名避免链接冲突,因为 rain / snow 编译进**不同**
/// MTLLibrary,不会真的冲突,但 namespace 分开更干净)。
inline float rain_hash_unit(uint x) {
    x = (x ^ 61u) ^ (x >> 16u);
    x = x + (x << 3u);
    x = x ^ (x >> 4u);
    x = x * 0x27D4EB2Du;
    x = x ^ (x >> 15u);
    return float(x & 0x00FFFFFFu) / float(0x01000000u);
}
"""
}
