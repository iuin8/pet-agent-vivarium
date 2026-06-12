/// 雨 render pipeline 的 vertex + fragment MSL 源。
///
/// Vertex shader 把每颗 `GpuRainParticle` 转成 **4-vertex strip(triangle
/// strip)** = 1 个竖向拉长的 quad(stretched along velocity 方向)。这种
/// "stretched quad" 是经典 motion blur 技巧:
/// - 主雨 velocity 向下,quad 沿速度方向拉长 → 拖出一道竖白线
/// - splash 子粒子 velocity 横向,quad 沿横向短一点 → 一颗小斜线点
///
/// 一个 instance = 1 颗粒子。vertex shader 用 `vertex_id` (0/1/2/3)
/// 在 4 个 corner 间选位,通过粒子 velocity 的归一化方向构造正交基
/// (tangent + normal)做"长方形 oriented along velocity":
///   - tangent = normalize(velocity + wind_tilt_vector)
///                                ^^^^^^^^^^^^^^^^^^^^
///   - normal  = perpendicular(tangent)
///   - 顶点位置 = particle_position
///                + tangent · (length/2) · (vertex_id < 2 ? -1 : +1)
///                + normal  · (width/2)  · (vertex_id % 2 == 0 ? -1 : +1)
///
/// **任务 B**:tangent 用 `velocity + (windTiltX, 0)` 规范化,放大 X
/// 分量让暴雨在视觉上倾斜更明显。windTiltX 由 coordinator 端用
/// `effectiveWind × windTiltRatio` 算好,fragment 不直接参与。
///
/// **任务 C'**:wetnessIntensity > 0 时,主雨 quad 长度额外 ×(1 +
/// 2·wetness)、fragment 端 tail alpha 抬升 ×(1 + 0.6·wetness),
/// 模拟玻璃湿润感"水痕"(无需独立 render pass)。
///
/// Fragment shader 根据 quad 内部 v 坐标(0 = 头部 / 1 = 尾部)做 motion
/// blur alpha gradient:头部 alpha 0.9,尾部 alpha 0.3,quad 边缘做软
/// 衰减避免 hard edge。
///
/// **半透明白色雨线**。颜色不参数化(暴雨视觉就是白)。
enum RainRenderShaderSource {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct GpuRainParticle {
    float2 position;
    float2 velocity;
    float  lifetime;
    uint   seed;
};

struct RainRenderUniforms {
    float2 viewport_size;     // 单位 logical pt
    float  drop_width;        // quad 宽度 (pt),典型 1.5
    float  drop_length;       // quad 最大长度 (pt),典型 12
    float  wind_tilt_x;       // 任务 B:tangent X 额外偏置 (px/s, windX × ratio)
    float  wetness_intensity; // 任务 C':0..1 玻璃湿润感强度
};

struct RainVertexOut {
    float4 position [[position]];
    float2 quad_uv;            // (0..1, 0..1) 用于 fragment 算 alpha
    float  alpha_factor;       // 整体 alpha multiplier (寿命渐隐 + splash 衰减)
    float  wetness_intensity;  // 透传给 fragment 决定 tail 拖长程度
    float  is_splash;          // 0=主雨, 1=splash — 让 fragment 区分两套 alpha
};

/// 4-vertex triangle strip 的角点偏移(在 quad 局部空间,长边方向 ±,
/// 宽边方向 ±)。vertex_id ∈ {0,1,2,3}。
inline float2 rain_quad_corner(uint vid) {
    // vid: 0=(-w,-l), 1=(+w,-l), 2=(-w,+l), 3=(+w,+l)
    // 注意 triangle strip 顺序:0 1 2 3 形成两个三角(0,1,2) (2,1,3)
    float wx = (vid & 1u) == 0u ? -1.0 : 1.0;
    float ly = (vid & 2u) == 0u ? -1.0 : 1.0;
    return float2(wx, ly);
}

vertex RainVertexOut rain_vertex(
    uint vid              [[vertex_id]],
    uint iid              [[instance_id]],
    device const GpuRainParticle* particles [[buffer(0)]],
    constant RainRenderUniforms& u           [[buffer(1)]]
) {
    GpuRainParticle p = particles[iid];

    // splash 子粒子识别(同 kernel 端):velocity.y > 0
    bool is_splash = (p.velocity.y > 0.0);

    // 任务 B:把 windTiltX 当作"假装这颗粒子还有这么多横向速度"叠加
    // 到 velocity 里再归一化 → quad 倾斜角度更大。splash 子粒子已经
    // 是横向飞、不再受 wind 主导,不应用 tilt(否则 splash 反而被拍
    // 偏)。
    float2 vel = p.velocity;
    if (!is_splash) {
        vel.x += u.wind_tilt_x;
    }
    float speed = length(vel);
    float2 tangent;
    if (speed < 1e-3) {
        tangent = float2(0.0, -1.0);
    } else {
        tangent = vel / speed;
    }
    float2 normal = float2(-tangent.y, tangent.x);

    // 主雨长 12pt、splash 短 ~4pt(横向小斜线)。任务 C':主雨 quad
    // 在 wetness 强度下额外拉长 ×(1 + 2·wetness),最高 ×3 时画出明显
    // 拖尾水痕。splash 不动(它本来就是短弹跳)。
    float wet = clamp(u.wetness_intensity, 0.0, 1.0);
    float wet_length_boost = is_splash ? 1.0 : (1.0 + 2.0 * wet);
    float length_px = is_splash ? (u.drop_length * 0.35) : (u.drop_length * wet_length_boost);
    float width_px  = is_splash ? (u.drop_width  * 0.6)  : u.drop_width;

    float2 corner = rain_quad_corner(vid);  // ±1 in each axis
    float2 offset = tangent * (length_px * 0.5 * corner.y)
                  + normal  * (width_px  * 0.5 * corner.x);

    float2 world_pos = p.position + offset;
    // 屏幕 NDC:(world / viewport) * 2 - 1。Y 轴跟 SnowVertexOut 同 —
    // 粒子坐标系是 bottom-origin,跟 NDC 同向,不翻 Y。
    float2 ndc = (world_pos / u.viewport_size) * 2.0 - 1.0;

    RainVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    // quad_uv:(corner+1)/2 → x in [0,1], y in [0,1]。y=0 头部(velocity 末端),
    // y=1 尾部(velocity 起点)。
    out.quad_uv = (corner + 1.0) * 0.5;

    // 整体 alpha 衰减:
    //   - splash:lifetime 0.1→0 线性渐隐,峰值 0.7
    //   - 主雨:lifetime 接近 0(<0.1)时渐隐,其余满
    float life = p.lifetime;
    float alpha;
    if (is_splash) {
        alpha = clamp(life / 0.1, 0.0, 1.0) * 0.7;
    } else {
        alpha = clamp(life / 0.1, 0.0, 1.0);  // 寿命 > 0.1 时是 1
        alpha = min(alpha, 1.0);
    }
    out.alpha_factor = alpha;
    out.wetness_intensity = wet;
    out.is_splash = is_splash ? 1.0 : 0.0;
    return out;
}

fragment float4 rain_fragment(
    RainVertexOut in                 [[stage_in]],
    constant RainRenderUniforms& u   [[buffer(1)]]
) {
    // quad_uv.y 0=头部、1=尾部 → motion blur gradient
    // 头部 alpha 0.9,尾部 alpha 0.3
    float head_to_tail = 1.0 - in.quad_uv.y;  // 1 头部,0 尾部
    float blur_alpha = mix(0.3, 0.9, head_to_tail);

    // 任务 C':wetness > 0 时,主雨 tail alpha 抬升 — 配合 vertex
    // 端 quad 拉长,视觉上像水痕残影留在玻璃上。splash 不动。
    bool is_splash = in.is_splash > 0.5;
    if (!is_splash) {
        // tail (head_to_tail 接近 0) 增益最强,head (≈1) 不变。
        float tail_mask = 1.0 - head_to_tail;  // 1 尾部,0 头部
        float tail_boost = 1.0 + 0.6 * in.wetness_intensity * tail_mask;
        blur_alpha *= tail_boost;
    }

    // 横向(quad_uv.x)软衰减:中心 1.0,左右边缘 0,sin 半周期最自然
    float side = sin(in.quad_uv.x * 3.14159265);
    float core_alpha = blur_alpha * side;

    // 整体 multiplier(寿命渐隐 / splash 半透明)
    float final_alpha = core_alpha * in.alpha_factor;
    if (final_alpha <= 0.001) { discard_fragment(); }
    return float4(1.0, 1.0, 1.0, final_alpha);
}
"""
}
