// swift-tools-version: 5.10
import Foundation
import PackageDescription

let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist")
    .path

let package = Package(
    name: "PhotosBackup",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhotosBackupCore", targets: ["PhotosBackupCore"]),
        .executable(name: "photo-backup", targets: ["photos-backup"])
    ],
    targets: [
        .target(name: "PhotosBackupCore"),
        .executableTarget(
            name: "photos-backup",
            dependencies: ["PhotosBackupCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "PhotosBackupCoreTests", dependencies: ["PhotosBackupCore"])
    ]
)
