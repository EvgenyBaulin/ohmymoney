// swift-tools-version: 6.1
// AppCore: pure Swift + Foundation only. It must build on macOS, Linux and, later, Windows.
// No AppKit, SwiftUI, GRDB, Charts, CryptoKit or Sparkle may ever appear here.
//
// The code is split into focused targets. `CoreKit` holds the shared value types and
// contracts; every other target builds on it and nothing else, so the targets can be
// developed and compiled independently. The one exception is `CoreAnalytics`: the numbers
// of Overview, Analytics and Reports must follow the accounting rules exactly, so it builds
// on `CoreAccounting` (and on `CoreCSV` for the report export) instead of copying them.
// `AppCore` is the umbrella the app imports.
import PackageDescription

let coreTargets = [
  "CoreParse", "CoreCSV", "CoreSample", "CoreArchive", "CoreRates", "CoreAccounting",
  "CorePipeline", "CoreAnalytics", "CorePlanning", "CoreLog", "CoreModel", "CoreInsights",
  "CoreGuide", "CoreSync",
]

let package = Package(
  name: "AppCore",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    // `make eval-model`: what the category model is worth on a CSV export. An executable of
    // the package, so it runs on Linux today and on Windows later, exactly like the model it
    // measures.
    .executable(name: "ohmymoney-eval-model", targets: ["ohmymoney-eval-model"]),
    // The storage layer needs the shared value types only, so it does not have to wait
    // for the other core targets to compile.
    .library(name: "CoreKit", targets: ["CoreKit"]),
  ],
  targets: [
    .target(name: "CoreKit", swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "CoreParse", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "CoreCSV", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    // `CoreAccounting` is here for `OperationLink`: the sample writes the very links the
    // application writes, and a second copy of that format in the generator would be one
    // copy too many.
    .target(
      name: "CoreSample", dependencies: ["CoreKit", "CoreAccounting"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "CoreArchive", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "CoreRates", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    // The shape of a log line, the levels, the rotation and the rule about what may never be
    // written. It depends on nothing: the file it writes to belongs to the app, but what goes
    // in the file has to be the same on Linux and later on Windows, and testable without one.
    .target(name: "CoreLog", swiftSettings: [.swiftLanguageMode(.v6)]),
    // The category model. It knows a flat list of examples and nothing about the ledger,
    // so `make eval-model` can use it without dragging the accounting in, and its tests are
    // written by hand rather than generated. `CoreArchive` is here for its
    // SHA-256, which the model file's checksum needs.
    .target(
      name: "CoreModel", dependencies: ["CoreKit", "CoreArchive", "CoreCSV"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // Where the ledger and the model meet: the one target that knows both, so neither has to
    // know the other. The anomalies live here too — they are the first thing that needs
    // the ledger, the planning book and the model at once.
    .target(
      name: "CoreInsights",
      dependencies: [
        "CoreKit", "CoreAccounting", "CoreAnalytics", "CorePlanning", "CoreModel", "CoreParse",
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "CoreAccounting", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "CorePipeline", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "CoreAnalytics", dependencies: ["CoreKit", "CoreAccounting", "CoreCSV"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // Planning and reconciliation and the debts screen read the ledger, so they build
    // on CoreAnalytics the same way it builds on CoreAccounting.
    .target(
      name: "CorePlanning", dependencies: ["CoreKit", "CoreAccounting", "CoreAnalytics"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // The guide as data — cards, scenarios, tasks and the conditions that find them done — so
    // every platform shows the same guide its own way.
    .target(
      name: "CoreGuide", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    // The change-journal exchange between devices: file format, idempotent order-free apply,
    // conflict rule, storage seams. Foundation only; no I/O of its own.
    .target(
      name: "CoreSync", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "AppCore",
      dependencies: ["CoreKit"] + coreTargets.map { .target(name: $0) },
      swiftSettings: [.swiftLanguageMode(.v6)]),

    .testTarget(
      name: "CoreKitTests", dependencies: ["CoreKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreParseTests", dependencies: ["CoreParse"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreCSVTests", dependencies: ["CoreCSV"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreSampleTests", dependencies: ["CoreSample", "CoreArchive"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreArchiveTests", dependencies: ["CoreArchive"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreRatesTests", dependencies: ["CoreRates"], resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreGuideTests", dependencies: ["CoreGuide"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreSyncTests", dependencies: ["CoreSync"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreLogTests", dependencies: ["CoreLog"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(
      name: "ohmymoney-eval-model", dependencies: ["CoreModel", "CoreCSV", "CoreKit"],
      swiftSettings: [.swiftLanguageMode(.v6)]),

    .testTarget(
      name: "CoreModelTests", dependencies: ["CoreModel"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // The CSV export `make eval-model` is checked on: committed so the tool has something to
    // run against on an unbuilt tree, and compared with the generator on every run. The test
    // reads and rewrites it in the source tree (`#filePath`: a package test runs outside the
    // sandbox, so it may), so it is no bundle resource: excluded, not copied.
    .testTarget(
      name: "CoreInsightsTests", dependencies: ["CoreInsights", "CoreSample", "CoreParse"],
      exclude: ["Fixtures"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CoreAccountingTests", dependencies: ["CoreAccounting"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CorePipelineTests", dependencies: ["CorePipeline"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    // The golden fixture is a bundle resource read through `Bundle.module`, never through a
    // repository path, so the suite runs the same on Linux. The synthetic histories and
    // their known answers come from `CoreSample`.
    .testTarget(
      name: "CoreAnalyticsTests", dependencies: ["CoreAnalytics", "CoreSample", "CorePlanning"],
      resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "CorePlanningTests", dependencies: ["CorePlanning", "CoreSample"],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ]
)
