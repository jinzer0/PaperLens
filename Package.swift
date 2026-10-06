// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "PaperLensTopology",
  platforms: [.macOS(.v15)],
  products: [.library(name: "ProviderRPC", targets: ["ProviderRPC"])],
  targets: [
    .target(
      name: "ProviderRPC",
      path: "Contracts/ProviderRPC",
      exclude: ["provider_rpc.py"],
      sources: ["ProviderRPC.swift"],
      resources: [.copy("contract.json")]
    ),
    .testTarget(
      name: "ProviderRPCTests",
      dependencies: ["ProviderRPC"],
      path: "Tests/Topology",
      exclude: [
        "FixtureGroupOwner.swift", "FixtureGroupOwner-Info.plist",
        "FixtureGroupOwner.entitlements", "fixture-map.json", "test_acquire.py", "test_agent.py",
        "test_package.py", "test_provider_rpc.py",
        "ReportPublicationTests.swift", "ActorIdentityProbe.swift",
        "PDFiumRollTests.cpp", "test_pdfium_roll.py",
      ],
      sources: ["ProviderRPCTests.swift"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
