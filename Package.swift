// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhotosBackup",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhotosBackupCore", targets: ["PhotosBackupCore"]),
        .executable(name: "photos-backup", targets: ["photos-backup"])
    ],
    targets: [
        .target(name: "PhotosBackupCore"),
        .executableTarget(name: "photos-backup", dependencies: ["PhotosBackupCore"]),
        .testTarget(name: "PhotosBackupCoreTests", dependencies: ["PhotosBackupCore"])
    ]
)
