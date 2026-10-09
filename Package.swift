// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "PaperLensTopology",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "ProviderRPC", targets: ["ProviderRPC"]),
    .library(name: "ProviderRequest", targets: ["ProviderRequest"]),
    .library(name: "PDFReadiness", targets: ["PDFReadiness"]),
    .library(name: "PaperLensProduct", targets: ["PaperLensProduct"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", revision: "b83108d10f42680d78f23fe4d4d80fc88dab3212"),
  ],
  targets: [
    .target(
      name: "PaperLensProduct",
      dependencies: ["ProviderRequest", "ProviderRPC", .product(name: "GRDB", package: "GRDB.swift")],
      path: "PaperLensApp",
      exclude: ["App/PaperLensApp.swift", "App/TopologyFixtures.swift", "App/PackagedDBProbe.swift",
        "App/PaperLens.entitlements", "App/Info.plist"],
      sources: [
        "App/ProductAppComposition.swift",
        "Application/JobRecoveryPolicy.swift",
        "Application/LocalLibraryLifecycle.swift",
        "Application/LibraryReadLeaseProvider.swift",
        "Application/LibraryURLImportWriter.swift",
        "Application/NativeAPIKeyConnection.swift",
        "Application/ProviderSettingsService.swift",
        "Application/ReaderSession.swift",
        "Application/AnnotationService.swift",
        "Application/FolderImportService.swift",
        "Application/URLImportService.swift",
        "Application/ExtractionRevisionService.swift",
        "Application/ReaderMetadataService.swift",
        "Application/LibraryOrganizationService.swift",
        "Domain/PDFGeometry.swift",
        "Adapters/PDFKitGeometryAdapter.swift",
        "Adapters/HTTPSPDFImportAdapter.swift",
        "Infrastructure/ProductDatabase.swift",
        "Infrastructure/APIKeySlotStore.swift",
        "Infrastructure/DatabaseAPIKeySelector.swift",
        "Infrastructure/ProductDatabase+Reader.swift",
        "Infrastructure/ProductDatabase+Annotations.swift",
        "Infrastructure/ProductDatabase+Folders.swift",
        "Infrastructure/ProductDatabase+Extraction.swift",
        "Infrastructure/ProductDatabase+ReaderMetadata.swift",
        "Infrastructure/ProductDatabase+Organization.swift",
        "Infrastructure/ProductDatabase+LibraryFacts.swift",
        "Features/Library/LibraryView.swift",
        "Features/Onboarding/APIKeyConnectionView.swift",
        "Features/Settings/ProviderSettingsView.swift",
        "Features/Reader/NativeReaderView.swift",
        "Features/Reader/AnnotationInspector.swift",
        "Features/Reader/ParsingStatusView.swift",
        "Features/Reader/MetadataOutlineView.swift",
        "Features/Library/ImportConfirmationView.swift",
        "Features/Library/URLImportView.swift",
        "Features/Library/LibraryBrowserView.swift",
        "Features/Library/ProductWorkspaceView.swift",
      ]
    ),
    .testTarget(
      name: "ProductTests",
      dependencies: ["PaperLensProduct", .product(name: "GRDB", package: "GRDB.swift")],
      path: "Tests/Product",
      sources: ["LocalLibraryLifecycleTests.swift", "APIKeyConnectionTests.swift", "ProductCompositionTests.swift",
        "ProviderSettingsTests.swift", "ReaderSessionTests.swift", "AnnotationServiceTests.swift",
        "FolderImportTests.swift", "URLImportTests.swift", "PDFGeometryTests.swift",
        "ExtractionRevisionTests.swift", "ReaderMetadataTests.swift", "LibraryOrganizationTests.swift",
        "LibraryReadLeaseTests.swift", "ProductWorkspaceTests.swift", "LibraryURLImportWriterTests.swift"]
    ),
    .target(
      name: "PDFReadiness",
      dependencies: ["ProviderRequest"],
      path: "Contracts/PDFReadiness"
    ),
    .testTarget(
      name: "PDFReadinessTests",
      dependencies: ["PDFReadiness", "ProviderRequest"],
      path: "Tests/PDFReadiness"
    ),
    .target(
      name: "ProviderRequest",
      path: "Contracts/ProviderRequest",
      exclude: ["provider_request.py"],
      sources: ["ProviderRequest.swift"],
      resources: [.copy("contract.json")]
    ),
    .testTarget(
      name: "ProviderRequestTests",
      dependencies: ["ProviderRequest"],
      path: "Tests/Contracts",
      exclude: ["test_provider_request.py"],
      sources: ["ProviderRequestTests.swift"]
    ),
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
        "test_package.py", "test_provider_rpc.py", "test_dependency_lock.py", "test_packaged_db.py",
        "test_agent_matrix.py", "PackagedDBProbeTests.swift", "JobRecoveryPolicyTests.swift",
        "ReportPublicationTests.swift", "ActorIdentityProbe.swift",
        "PDFiumRollTests.cpp", "test_pdfium_roll.py",
      ],
      sources: ["ProviderRPCTests.swift"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
