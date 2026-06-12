// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vivarium",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Context", targets: ["Context"]),
        .library(name: "RuntimeBridge", targets: ["RuntimeBridge"]),
        .library(name: "Rendering", targets: ["Rendering"]),
        .library(name: "ShimejiImport", targets: ["ShimejiImport"]),
        .library(name: "PetCatalog", targets: ["PetCatalog"]),
        .library(name: "PetBehavior", targets: ["PetBehavior"]),
    ],
    targets: [
        .target(name: "Context", path: "Sources/Context"),
        .target(name: "RuntimeBridge", dependencies: ["Context"], path: "Sources/RuntimeBridge"),
        .target(
            name: "Rendering",
            dependencies: ["RuntimeBridge"],
            path: "Sources/Rendering",
            exclude: ["Shaders/Orb.metal"],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit")]
        ),
        .target(
            name: "ShimejiImport",
            dependencies: [],
            path: "Sources/ShimejiImport",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ImageIO")]
        ),
        .target(name: "PetCatalog", dependencies: [], path: "Sources/PetCatalog"),
        // PetBehavior:数据驱动 Shimeji 行为状态机(加权随机 + NextBehavior 转移图 +
        // 条件门控)。deps[](pickNext 对 RandomNumberGenerator 泛型,不绑具体 RNG)。链
        // JavaScriptCore(系统框架)做 Shimeji 条件求值器;接 RuntimeBridge 出运动语汇。
        .target(
            name: "PetBehavior",
            dependencies: [],
            path: "Sources/PetBehavior",
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(name: "ContextTests", dependencies: ["Context"], path: "Tests/ContextTests"),
        .testTarget(name: "RuntimeBridgeTests", dependencies: ["RuntimeBridge", "Context"], path: "Tests/RuntimeBridgeTests"),
        .testTarget(name: "RenderingTests", dependencies: ["Rendering", "RuntimeBridge", "Context"], path: "Tests/RenderingTests"),
        .testTarget(name: "ShimejiImportTests", dependencies: ["ShimejiImport"], path: "Tests/ShimejiImportTests"),
        .testTarget(name: "PetCatalogTests", dependencies: ["PetCatalog"], path: "Tests/PetCatalogTests"),
        .testTarget(name: "PetBehaviorTests", dependencies: ["PetBehavior"], path: "Tests/PetBehaviorTests"),
    ]
)
