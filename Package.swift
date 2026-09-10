// swift-tools-version: 6.0
// SimpleShrink — shrink Linux disk images on macOS.
// Copyright (C) 2026 OptoSmart. Licensed under GPL-2.0-only, see COPYING.

import PackageDescription

let package = Package(
    name: "SimpleShrink",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "simpleshrink", targets: ["simpleshrink"]),
        .library(name: "SimpleShrinkKit", targets: ["SimpleShrinkKit"]),
    ],
    targets: [
        .target(name: "SimpleShrinkKit"),
        .executableTarget(name: "simpleshrink", dependencies: ["SimpleShrinkKit"]),
        .testTarget(name: "SimpleShrinkKitTests", dependencies: ["SimpleShrinkKit"]),
    ]
)
