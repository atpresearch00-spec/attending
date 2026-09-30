// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Attending", platforms: [.macOS("14.2")], products: [
    .executable(name: "Attending", targets: ["Attending"]),
    .executable(name: "attending-bridge", targets: ["AttendingBridge"]),
    .library(name: "AttendingCore", targets: ["AttendingCore"]),
    .library(name: "AttendingMedia", type: .dynamic, targets: ["AttendingMedia"])
], targets: [
    .target(name: "AttendingCore"),
    .target(name: "AttendingMedia", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
    .executableTarget(name: "Attending", dependencies: ["AttendingCore"]),
    .executableTarget(name: "AttendingBridge", dependencies: ["AttendingCore"]),
    .executableTarget(name: "AttendingCoreChecks", dependencies: ["AttendingCore"], path: "Tests/AttendingCoreTests")
])
