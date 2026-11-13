// swift-tools-version: 6.2
import PackageDescription

/// TrackPal 的判斷邏輯與系統整合層。
///
/// - `TrackPalCore`：純邏輯（區域判定、意圖 gate、手勢狀態機、慣性模型、軌跡格式）。
///   不送任何事件、不碰私有 framework，所以 `swift test` 就能把整條手勢流程跑完。
/// - `TrackPalSystem`：macOS 整合（合成 CGEvent、event tap、display link、日誌、
///   軌跡檔、設定儲存）。不含 MultitouchSupport，那一層留在 App target。
/// - `trackpal-replay`：把實機軌跡丟進真正的 gate／狀態機重算的命令列工具。
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "TrackPalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrackPalCore", targets: ["TrackPalCore"]),
        .library(name: "TrackPalSystem", targets: ["TrackPalSystem"]),
        .executable(name: "trackpal-replay", targets: ["trackpal-replay"]),
    ],
    targets: [
        .target(
            name: "TrackPalCore",
            swiftSettings: upcomingFeatures
        ),
        .target(
            name: "TrackPalSystem",
            dependencies: ["TrackPalCore"],
            swiftSettings: upcomingFeatures
        ),
        .executableTarget(
            name: "trackpal-replay",
            dependencies: ["TrackPalCore"],
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "TrackPalCoreTests",
            dependencies: ["TrackPalCore"],
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "TrackPalSystemTests",
            dependencies: ["TrackPalSystem", "TrackPalCore"],
            swiftSettings: upcomingFeatures
        ),
    ],
    swiftLanguageModes: [.v6]
)
