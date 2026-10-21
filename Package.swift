// swift-tools-version:5.9
import PackageDescription

// NodoCore es el nucleo logico de la app: Foundation puro, sin UIKit ni SwiftUI.
// Eso permite compilarlo y probarlo en Windows con `swift test`, sin simulador
// ni Xcode, que es justo lo que necesitamos para no depender de la nube en cada
// cambio pequeno.
let package = Package(
    name: "NodoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "NodoCore", targets: ["NodoCore"])
    ],
    targets: [
        .target(
            name: "NodoCore",
            path: "NodoCore/Sources/NodoCore"
        ),
        .testTarget(
            name: "NodoCoreTests",
            dependencies: ["NodoCore"],
            path: "NodoCore/Tests/NodoCoreTests"
        )
    ]
)
