import Metal
import Testing
import simd
@testable import Rendering

// MARK: - Particle struct layout

@Test("RainGPUParticle has expected Metal-friendly stride (24 bytes)")
func rainGPUParticleStride() {
    // position(8) + velocity(8) + lifetime(4) + seed(4) = 24 bytes
    #expect(MemoryLayout<RainGPUParticle>.stride == 24)
    #expect(MemoryLayout<RainGPUParticle>.alignment == 8)
}

@Test("RainSimulationUniforms has expected stride and alignment")
func rainSimulationUniformsStride() {
    // 任务 #64 后字段:
    //   dt(4) + worldSize(8) + frameIndex(4) + particleCount(4) +
    //   windX(4) + gravity(4) + collisionRectCount(4) +
    //   pileCellGridSize(SIMD2<UInt32> = 8) + pileCellSize(SIMD2<Float> = 8) +
    //   hasPileBuffer(4) = 52 bytes 原始,SIMD2 8-byte 对齐 → stride 至少 56。
    // 严格 assert stride >= 56 + 4-multiple,确保 MSL constant 绑定对齐稳定。
    let stride = MemoryLayout<RainSimulationUniforms>.stride
    #expect(stride > 0)
    #expect(stride % 4 == 0)
    #expect(stride >= 56)  // task #64 added pileCellGridSize + pileCellSize + hasPileBuffer
}

@Test("RainCollisionRect has Metal-friendly 16-byte stride")
func rainCollisionRectStride() {
    // 4 × Float = 16 bytes. Critical: must match MSL `GpuRainCollisionRect`
    // struct layout in RainKernelShared so kernel reads correct rect data.
    #expect(MemoryLayout<RainCollisionRect>.stride == 16)
    #expect(MemoryLayout<RainCollisionRect>.alignment == 4)
}

@Test("RainRenderUniforms stride accommodates new windTiltX + wetnessIntensity")
func rainRenderUniformsStride() {
    // viewportSize(8) + dropWidth(4) + dropLength(4) + windTiltX(4)
    // + wetnessIntensity(4) = 24 bytes. SIMD2<Float> aligns to 8 so the
    // struct stride should be a multiple of 8 (24 itself is a multiple
    // of 8, no trailing pad needed).
    let stride = MemoryLayout<RainRenderUniforms>.stride
    #expect(stride >= 24)
    #expect(stride % 4 == 0)
}

// MARK: - Coordinator construction + seed

@Test("GPURainCoordinator constructs successfully on Metal device")
@MainActor
func rainCoordinatorConstructs() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 64
    ))
    #expect(coordinator.particleCapacity == 64)
    #expect(coordinator.activeParticleCount == 0)
    #expect(coordinator.frameIndex == 0)
}

@Test("GPURainCoordinator seeds buffer with stable per-slot seed and dead lifetime")
@MainActor
func rainCoordinatorSeedsBuffer() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 16
    ))
    let snapshot = coordinator.snapshot(count: 16)
    #expect(snapshot.count == 16)
    // All dead at seed time — lifetime 0, position.y negative (below world).
    // kernel respawn block hands each one a random visible (x, y) on frame 1.
    for p in snapshot {
        #expect(p.lifetime == 0)
        #expect(p.position.y < 0)
        // velocity.y < 0 so kernel treats as main rain (not splash)
        #expect(p.velocity.y < 0)
    }
    // Seeds should differ per slot (stable hash of index).
    let seeds = snapshot.map(\.seed)
    let uniqueSeeds = Set(seeds)
    #expect(uniqueSeeds.count == seeds.count)
}

// MARK: - tick state machine

@Test("GPURainCoordinator tick flips activeParticleCount on isRainEnabled toggle")
@MainActor
func rainCoordinatorTickFlipsActiveCount() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 32
    ))

    #expect(coordinator.activeParticleCount == 0)

    let u1 = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 0)
    #expect(u1.particleCount == 32)  // ramps to capacity immediately
    #expect(coordinator.activeParticleCount == 32)
    #expect(coordinator.frameIndex == 1)

    let u2 = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: false, windX: 0)
    #expect(u2.particleCount == 0)
    #expect(coordinator.activeParticleCount == 0)
    #expect(coordinator.frameIndex == 2)
}

@Test("GPURainCoordinator tick clamps oversized dt to prevent particle teleport")
@MainActor
func rainCoordinatorClampsDt() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 16
    ))
    let u = coordinator.tick(dt: 5.0, isRainEnabled: true, windX: 0)
    // dt clamped to [0, 1/30]; uniforms.dt must be ≤ 1/30 + small epsilon
    #expect(u.dt <= Float(1.0 / 30.0) + 1e-5)
    #expect(u.dt > 0)
}

@Test("GPURainCoordinator tick writes wind into uniforms (external override wins)")
@MainActor
func rainCoordinatorExternalWindOverridesParameter() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 8
    ))
    coordinator.externalWindX = 100
    let u = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 50)
    // externalWindX overrides parameter — kernel side will see 100, not 50.
    #expect(u.windX == 100)
}

// MARK: - start/stop semantics

@Test("GPURainCoordinator start fills active to capacity, stop clears")
@MainActor
func rainCoordinatorStartStop() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 64
    ))
    coordinator.start()
    #expect(coordinator.activeParticleCount == 64)
    coordinator.stop()
    #expect(coordinator.activeParticleCount == 0)
    // Idempotent
    coordinator.stop()
    #expect(coordinator.activeParticleCount == 0)
}

// MARK: - encodeFrame end-to-end (compute + render)

@Test("GPURainCoordinator encodes a real compute+render frame without crashing")
@MainActor
func rainCoordinatorEncodesFrame() throws {
    let device = try #require(SharedMetal.device)
    let queue = try #require(SharedMetal.commandQueue)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 256
    ))
    // Need a real render target — use an offscreen texture as the color attachment.
    let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 256,
        height: 256,
        mipmapped: false
    )
    texDescriptor.usage = [.renderTarget, .shaderRead]
    let texture = try #require(device.makeTexture(descriptor: texDescriptor))

    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .clear
    renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    renderPass.colorAttachments[0].storeAction = .store

    _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 30)
    let cmd = try #require(queue.makeCommandBuffer())
    coordinator.encodeFrame(
        into: cmd,
        renderPassDescriptor: renderPass,
        viewportWidth: 256,
        viewportHeight: 256
    )
    cmd.commit()
    cmd.waitUntilCompleted()

    #expect(cmd.status == .completed)
}

// MARK: - Task A: collision rect upload + kernel splash trigger

@Test("setCollisionRects writes rects into shared buffer up to capacity")
@MainActor
func rainCoordinatorAcceptsCollisionRects() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 32,
        collisionRectCapacity: 4
    ))
    // Empty starts as 0.
    #expect(coordinator.activeCollisionRectCount == 0)

    // Push three rects — within capacity.
    coordinator.setCollisionRects([
        RainCollisionRect(minX: 10, minY: 100, maxX: 200, maxY: 300),
        RainCollisionRect(minX: 50, minY: 400, maxX: 250, maxY: 600),
        RainCollisionRect(minX: 0,  minY: 0,   maxX: 800, maxY: 50)
    ])
    #expect(coordinator.activeCollisionRectCount == 3)

    let snap = coordinator.collisionRectsSnapshot(count: 3)
    #expect(snap.count == 3)
    #expect(snap[0].minX == 10)
    #expect(snap[0].maxY == 300)
    #expect(snap[2].maxX == 800)

    // Truncation to capacity.
    coordinator.setCollisionRects(Array(
        repeating: RainCollisionRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
        count: 99
    ))
    #expect(coordinator.activeCollisionRectCount == 4)
}

@Test("Kernel splash fires when a main raindrop crosses a collision rect top")
@MainActor
func rainCoordinatorKernelSplashesOnRectCrossing() throws {
    let device = try #require(SharedMetal.device)
    let queue = try #require(SharedMetal.commandQueue)
    // gravity 0 + tiny capacity so we control every particle precisely.
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 1,
        gravity: 0,
        collisionRectCapacity: 4
    ))

    // Place one rect at y=400 (top edge), wide span.
    coordinator.setCollisionRects([
        RainCollisionRect(minX: 0, minY: 100, maxX: 800, maxY: 400)
    ])

    // Hand-write a single main rain particle that will cross y=400 in one
    // step: position.y = 410, velocity.y = -1500 → next_y ≈ 410 - 1500*dt.
    // At dt = 1/60, next_y ≈ 410 - 25 = 385, which is < 400 (crosses top).
    let dt = 1.0 / 60.0
    let particlePtr = coordinator.particleBuffer.contents().bindMemory(
        to: RainGPUParticle.self, capacity: 1
    )
    particlePtr[0] = RainGPUParticle(
        position: SIMD2<Float>(400, 410),
        velocity: SIMD2<Float>(0, -1500),
        lifetime: 0.5,
        seed: 12345
    )
    coordinator.start()  // active count = 1

    _ = coordinator.tick(dt: dt, isRainEnabled: true, windX: 0)

    // Dispatch the compute kernel.
    let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
    )
    texDescriptor.usage = [.renderTarget]
    let texture = try #require(device.makeTexture(descriptor: texDescriptor))
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .clear
    renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    let cmd = try #require(queue.makeCommandBuffer())
    coordinator.encodeFrame(
        into: cmd,
        renderPassDescriptor: renderPass,
        viewportWidth: 800,
        viewportHeight: 600
    )
    cmd.commit()
    cmd.waitUntilCompleted()

    // After kernel: particle should have been splash-converted.
    //   velocity.y > 0  (splash going up)
    //   position.y ≈ rect_top + 0.5 = 400.5
    //   lifetime ≈ 0.1
    let after = coordinator.snapshot(count: 1)[0]
    #expect(after.velocity.y > 0, "splash velocity.y should flip positive (upward bounce)")
    #expect(abs(after.position.y - 400.5) < 1.0, "splash should land near rect_top (got \(after.position.y))")
    #expect(after.lifetime > 0 && after.lifetime <= 0.11, "splash lifetime should be ~0.1 (got \(after.lifetime))")
}

@Test("Kernel does NOT splash if particle x is outside rect horizontal range")
@MainActor
func rainCoordinatorKernelSkipsSplashWhenXOutsideRect() throws {
    let device = try #require(SharedMetal.device)
    let queue = try #require(SharedMetal.commandQueue)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 1,
        gravity: 0,
        collisionRectCapacity: 4
    ))
    // Rect at x ∈ [200, 400], y_top = 300.
    coordinator.setCollisionRects([
        RainCollisionRect(minX: 200, minY: 100, maxX: 400, maxY: 300)
    ])

    // Particle at x = 700 (way right of rect), crossing y = 300 vertically.
    let dt = 1.0 / 60.0
    let ptr = coordinator.particleBuffer.contents().bindMemory(
        to: RainGPUParticle.self, capacity: 1
    )
    ptr[0] = RainGPUParticle(
        position: SIMD2<Float>(700, 310),
        velocity: SIMD2<Float>(0, -1500),
        lifetime: 0.5,
        seed: 99
    )
    coordinator.start()
    _ = coordinator.tick(dt: dt, isRainEnabled: true, windX: 0)

    let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
    )
    texDescriptor.usage = [.renderTarget]
    let texture = try #require(device.makeTexture(descriptor: texDescriptor))
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .clear

    let cmd = try #require(queue.makeCommandBuffer())
    coordinator.encodeFrame(
        into: cmd, renderPassDescriptor: renderPass,
        viewportWidth: 800, viewportHeight: 600
    )
    cmd.commit()
    cmd.waitUntilCompleted()

    // Particle x=700 is outside [200, 400] → no splash. velocity.y still
    // negative (still falling), position continues downward.
    let after = coordinator.snapshot(count: 1)[0]
    #expect(after.velocity.y < 0, "particle outside rect x-range should NOT splash; velocity stays negative")
}

// MARK: - Task C': wetness intensity lerp

@Test("wetnessIntensity lerps toward 1 when rain enabled, toward 0 when disabled")
@MainActor
func rainCoordinatorWetnessLerps() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 8,
        wetnessLerpPerFrame: 0.1  // bigger step → fewer ticks to observe
    ))
    #expect(coordinator.wetnessIntensity == 0)

    // Tick a few times with rain on → wetness climbs.
    for _ in 0..<3 {
        _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 0)
    }
    #expect(coordinator.wetnessIntensity > 0.25)
    #expect(coordinator.wetnessIntensity <= 1.0)

    // Saturate at 1.
    for _ in 0..<20 {
        _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 0)
    }
    #expect(coordinator.wetnessIntensity == 1.0)

    // Toggle off → wetness fades back to 0.
    for _ in 0..<3 {
        _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: false, windX: 0)
    }
    #expect(coordinator.wetnessIntensity < 1.0)
    #expect(coordinator.wetnessIntensity >= 0)

    for _ in 0..<20 {
        _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: false, windX: 0)
    }
    #expect(coordinator.wetnessIntensity == 0)
}

// MARK: - 任务 #64: rain → pile water cell deposit

@Test("setPileBuffer wires reference + grid params (idempotent)")
@MainActor
func rainCoordinatorAcceptsPileBuffer() throws {
    let device = try #require(SharedMetal.device)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 8
    ))
    // 初始 nil — kernel 端 hasPileBuffer = 0,走 splash fallback。
    #expect(coordinator.pileCellBuffer == nil)
    #expect(coordinator.pileCellGridSize == .zero)

    // 造一个假 pile buffer(只为引用 hookup 测试,不真跑 kernel)。
    let dummyBytes = 16 * MemoryLayout<UInt32>.stride
    let dummyBuffer = try #require(device.makeBuffer(length: dummyBytes, options: [.storageModeShared]))
    coordinator.setPileBuffer(
        dummyBuffer,
        gridSize: SIMD2<UInt32>(4, 4),
        cellSize: SIMD2<Float>(4, 4)
    )
    #expect(coordinator.pileCellBuffer === dummyBuffer)
    #expect(coordinator.pileCellGridSize == SIMD2<UInt32>(4, 4))
    #expect(coordinator.pileCellSize == SIMD2<Float>(4, 4))

    // 解绑 nil — 回到旧 splash fallback 路径。
    coordinator.setPileBuffer(nil, gridSize: .zero, cellSize: .zero)
    #expect(coordinator.pileCellBuffer == nil)
}

@Test("Rain falls back to splash when pile buffer is not set (backward compat)")
@MainActor
func rainCoordinatorSplashFallbackWhenNoPileBuffer() throws {
    let device = try #require(SharedMetal.device)
    let queue = try #require(SharedMetal.commandQueue)
    // No setPileBuffer call → pileCellBuffer == nil → kernel has_pile_buffer = 0
    // → 老 splash 路径。这是 GPURainCoordinatorTests.swift 原有
    // rainCoordinatorKernelSplashesOnRectCrossing 测试的精神延续 —
    // 验证我们没有不小心破坏向后兼容。
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 1,
        gravity: 0,
        collisionRectCapacity: 4
    ))
    coordinator.setCollisionRects([
        RainCollisionRect(minX: 0, minY: 100, maxX: 800, maxY: 400)
    ])
    let dt = 1.0 / 60.0
    let particlePtr = coordinator.particleBuffer.contents().bindMemory(
        to: RainGPUParticle.self, capacity: 1
    )
    particlePtr[0] = RainGPUParticle(
        position: SIMD2<Float>(400, 410),
        velocity: SIMD2<Float>(0, -1500),
        lifetime: 0.5,
        seed: 12345
    )
    coordinator.start()
    _ = coordinator.tick(dt: dt, isRainEnabled: true, windX: 0)

    let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
    )
    texDescriptor.usage = [.renderTarget]
    let texture = try #require(device.makeTexture(descriptor: texDescriptor))
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .clear

    let cmd = try #require(queue.makeCommandBuffer())
    coordinator.encodeFrame(
        into: cmd, renderPassDescriptor: renderPass,
        viewportWidth: 800, viewportHeight: 600
    )
    cmd.commit()
    cmd.waitUntilCompleted()

    // 仍然是 splash 行为:velocity.y > 0(向上反弹)。
    let after = coordinator.snapshot(count: 1)[0]
    #expect(after.velocity.y > 0, "no pile buffer → fallback splash; velocity should flip positive")
    #expect(abs(after.position.y - 400.5) < 1.0, "splash should land near rect_top")
}

@Test("GPURainCoordinator kernel respawns dead particles into visible band on first tick")
@MainActor
func rainCoordinatorKernelRespawnsOnFirstTick() throws {
    let device = try #require(SharedMetal.device)
    let queue = try #require(SharedMetal.commandQueue)
    let coordinator = try #require(GPURainCoordinator(
        device: device,
        particleCapacity: 32,
        gravity: 0  // disable gravity so respawn positions don't drift away
    ))

    // Snapshot before tick — all dead (y < 0).
    let before = coordinator.snapshot(count: 32)
    #expect(before.allSatisfy { $0.lifetime == 0 })

    _ = coordinator.tick(dt: 1.0 / 60.0, isRainEnabled: true, windX: 0)

    // Need a render pass to encode (even though we only care about compute).
    let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false
    )
    texDescriptor.usage = [.renderTarget]
    let texture = try #require(device.makeTexture(descriptor: texDescriptor))
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .clear
    renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    let cmd = try #require(queue.makeCommandBuffer())
    coordinator.encodeFrame(
        into: cmd,
        renderPassDescriptor: renderPass,
        viewportWidth: 400,
        viewportHeight: 800
    )
    cmd.commit()
    cmd.waitUntilCompleted()

    // After one tick: kernel respawn branch fired (lifetime was ≤ 0) →
    // each particle now has a non-zero lifetime and positive Y (visible
    // band sits at world_size.y + small offset).
    let after = coordinator.snapshot(count: 32)
    #expect(after.allSatisfy { $0.lifetime > 0 })
    #expect(after.allSatisfy { $0.position.y >= 0 })
}
