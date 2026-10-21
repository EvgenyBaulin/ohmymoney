// swift-tools-version: 6.1
// AppDatabase: the GRDB-backed storage layer for the macOS app. It owns migrations, records
// and repositories; all business rules stay in AppCore.
import PackageDescription

let package = Package(
  name: "AppDatabase",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    .library(name: "AppDatabase", targets: ["AppDatabase"])
  ],
  dependencies: [
    .package(path: "../AppCore"),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
  ],
  targets: [
    // A process of its own for the durability test: it writes an operation and then kills
    // itself with SIGKILL. `kill -9` cannot be survived, so the process being killed cannot
    // also be the one that checks afterwards.
    .executableTarget(
      name: "ohmymoney-durability-probe",
      dependencies: [
        "AppDatabase",
        .product(name: "AppCore", package: "AppCore"),
        .product(name: "CoreKit", package: "AppCore"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // `make migration-dry-run DB=<file>`: migrates a copy of a database file in a folder of its
    // own and prints what the update would do to it — table names, row counts and whether the
    // sums agree, never a value — so the update can be tried on the owner's data before it
    // ships, without opening the original.
    .executableTarget(
      name: "ohmymoney-migration-dry-run",
      dependencies: [
        "AppDatabase",
        .product(name: "AppCore", package: "AppCore"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "AppDatabase",
      dependencies: [
        .product(name: "AppCore", package: "AppCore"),
        .product(name: "CoreKit", package: "AppCore"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // The tests build their histories with the core's sample generator and check loaded
    // snapshots with its ledger, so they name the core product rather than reaching it
    // through the storage target.
    .testTarget(
      name: "AppDatabaseTests",
      dependencies: [
        "AppDatabase",
        .product(name: "AppCore", package: "AppCore"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
