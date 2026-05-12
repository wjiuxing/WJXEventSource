// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WJXEventSource",
    platforms: [.iOS(.v10)],
    products: [
        .library(
            name: "WJXEventSource",
            targets: ["WJXEventSource"]
        ),
    ],
    targets: [
        .target(
            name: "WJXEventSource",
            path: "WJXEventSource/Sources",
            exclude: ["WJXEventSource-Private.h"],
            publicHeadersPath: "."
        ),
    ]
)
