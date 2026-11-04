import CoreFoundation
import Darwin
import Foundation
import XCTest

@testable import PaperLensProduct

final class AgentPrivateBackupTests: XCTestCase {
  private var fixture: URL!
  private var agentScript: URL!

  override func setUpWithError() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    fixture = repository.appendingPathComponent(
      ".build/agent-backup-tests-" + UUID().uuidString.lowercased(), isDirectory: true)
    try makeDirectory(fixture)
    let resources = fixture.appendingPathComponent("resources", isDirectory: true)
    try makeDirectory(resources)
    for (source, name) in [
      ("ProviderAgent/agent.py", "agent.py"),
      ("Contracts/ProviderRPC/provider_rpc.py", "provider_rpc.py"),
      ("Contracts/ProviderRPC/contract.json", "contract.json"),
    ] {
      try FileManager.default.copyItem(
        at: repository.appendingPathComponent(source), to: resources.appendingPathComponent(name))
    }
    agentScript = resources.appendingPathComponent("agent.py")
  }

  override func tearDownWithError() throws {
    if let fixture { try FileManager.default.removeItem(at: fixture) }
    fixture = nil
    agentScript = nil
  }

  private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  private func excluded(_ url: URL) throws -> Bool {
    let target = url as CFURL
    CFURLClearResourcePropertyCache(target)
    var value: Unmanaged<AnyObject>?
    let copied = CFURLCopyResourcePropertyForKey(target, kCFURLIsExcludedFromBackupKey, &value, nil)
    let owned = value?.takeRetainedValue()
    guard copied, let flag = owned as? NSNumber else {
      throw NSError(domain: "AgentPrivateBackupFixture", code: 2)
    }
    return flag.boolValue
  }

  private func newOwner() throws -> (TopologyOwnedFixtures, URL) {
    let id = UUID().uuidString.lowercased()
    let owner = try XCTUnwrap(TopologyOwnedFixtures(root: fixture, runID: id))
    let directory = fixture.appendingPathComponent(id, isDirectory: true)
    return (owner, directory)
  }

  private func prepare(_ owner: TopologyOwnedFixtures) -> Bool {
    owner.prepareBackupExclusionFixture(agentScript: agentScript)
  }

  private func attributes(_ descriptor: Int32) throws -> [String: Data] {
    let size = flistxattr(descriptor, nil, 0, 0)
    guard size >= 0 else { throw NSError(domain: "AgentPrivateBackupFixture", code: Int(errno)) }
    var names = [CChar](repeating: 0, count: size)
    let count = flistxattr(descriptor, &names, names.count, 0)
    guard count == size else {
      throw NSError(domain: "AgentPrivateBackupFixture", code: Int(errno))
    }
    var result: [String: Data] = [:]
    for bytes in names.map({ UInt8(bitPattern: $0) }).split(separator: 0) {
      guard let name = String(bytes: bytes, encoding: .utf8) else {
        throw NSError(domain: "AgentPrivateBackupFixture", code: 3)
      }
      let length = fgetxattr(descriptor, name, nil, 0, 0, 0)
      guard length >= 0 else {
        throw NSError(domain: "AgentPrivateBackupFixture", code: Int(errno))
      }
      var data = Data(count: length)
      let read = data.withUnsafeMutableBytes {
        fgetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0)
      }
      guard read == length else {
        throw NSError(domain: "AgentPrivateBackupFixture", code: Int(errno))
      }
      result[name] = data
    }
    return result
  }

  func testActualOwnedRootExcludedBeforeCreatingRuntimeChildren() throws {
    let (owner, directory) = try newOwner()
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertTrue(prepare(owner))
    XCTAssertTrue(try excluded(directory))
    XCTAssertTrue(owner.hasBackupExclusion())
    XCTAssertTrue(owner.prepareRuntimeDirectories())
    var info = stat()
    XCTAssertEqual(fstatat(owner.descriptor, "codex", &info, AT_SYMLINK_NOFOLLOW), 0)
    XCTAssertEqual(info.st_uid, getuid())
    XCTAssertEqual(info.st_mode & 0o7777, 0o700)
    XCTAssertTrue(owner.hasBackupExclusion())
    XCTAssertTrue(owner.create("M"))
    XCTAssertTrue(owner.check())
    XCTAssertFalse(prepare(owner))
    XCTAssertTrue(try excluded(directory))
  }

  private func embeddedBundle(interpreterSymlink: URL? = nil) throws -> (URL, URL) {
    let main = fixture.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let bundle = main.appendingPathComponent("Contents/XPCServices/ProviderAgent.xpc")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try makeDirectory(contents.appendingPathComponent("Resources"))
    let plist = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": TopologyIdentity.agent, "CFBundlePackageType": "XPC!",
      ],
      format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    let interpreter = contents.appendingPathComponent("MacOS/python3")
    if let interpreterSymlink {
      try FileManager.default.createSymbolicLink(
        at: interpreter, withDestinationURL: interpreterSymlink)
    } else {
      let framework = contents.appendingPathComponent("Frameworks")
      try makeDirectory(framework)
      let executable = framework.appendingPathComponent("python3")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
      try FileManager.default.createSymbolicLink(at: interpreter, withDestinationURL: executable)
    }
    for name in ["agent.py", "sdk_worker.py", "broker_control.py"] {
      try Data("# synthetic nonexecuted bundle resource\n".utf8)
        .write(to: contents.appendingPathComponent("Resources/" + name))
    }
    return (main, bundle)
  }

  func testBundledWorkerRejectsExternalInterpreterSymlink() throws {
    let (owner, _) = try newOwner()
    let (main, _) = try embeddedBundle(interpreterSymlink: URL(fileURLWithPath: "/usr/bin/python3"))
    XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: main))
    XCTAssertTrue(owner.permitsNamespaceMutation)
  }

  func testBundledWorkerRejectsMissingInterpreterAndWrongBundleIdentity() throws {
    let (owner, _) = try newOwner()
    XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: fixture))
    let (main, bundle) = try embeddedBundle()
    try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/MacOS/python3"))
    XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: main))
    let (wrongMain, wrongBundle) = try embeddedBundle()
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "invalid.synthetic.bundle"], format: .xml, options: 0
    )
    try plist.write(to: wrongBundle.appendingPathComponent("Contents/Info.plist"))
    XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: wrongMain))
  }

  func testBundledWorkerAllowsOnlyCompleteInternalInterpreterBundle() throws {
    let (owner, _) = try newOwner()
    let (main, bundle) = try embeddedBundle()
    let launch = try XCTUnwrap(
      OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: main))
    XCTAssertTrue(launch.namespace === owner)
    XCTAssertEqual(launch.script, bundle.appendingPathComponent("Contents/Resources/agent.py"))
    for name in ["sdk_worker.py", "broker_control.py", "agent.py"] {
      let path = bundle.appendingPathComponent("Contents/Resources/" + name)
      let saved = try Data(contentsOf: path)
      try FileManager.default.removeItem(at: path)
      XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: main))
      try saved.write(to: path)
    }
    let resource = bundle.appendingPathComponent("Contents/Resources/sdk_worker.py")
    try FileManager.default.removeItem(at: resource)
    try FileManager.default.createSymbolicLink(at: resource, withDestinationURL: agentScript)
    XCTAssertNil(OwnedChildRetirement.WorkerLaunch.bundled(namespace: owner, mainBundle: main))
  }

  func testRuntimeDirectoriesNeverAdoptExistingEntryAndLeaseBlocksMutation() throws {
    let (owner, _) = try newOwner()
    XCTAssertTrue(prepare(owner))
    XCTAssertEqual(mkdirat(owner.descriptor, "codex", 0o700), 0)
    XCTAssertFalse(owner.prepareRuntimeDirectories())
    XCTAssertEqual(unlinkat(owner.descriptor, "codex", AT_REMOVEDIR), 0)
    XCTAssertTrue(owner.prepareRuntimeDirectories())
    let lease = UUID()
    XCTAssertTrue(owner.beginMetadataMutation(owner: lease))
    XCTAssertFalse(owner.prepareRuntimeDirectories())
    XCTAssertFalse(owner.cleanup())
    XCTAssertTrue(owner.prepareWorkerDirectories(owner: lease, permit: { true }))
    XCTAssertFalse(owner.prepareWorkerDirectories(owner: UUID(), permit: { true }))
    owner.endMetadataMutation(owner: lease)
    XCTAssertTrue(owner.cleanup())
  }

  func testRuntimeDirectoryReplacementIsNotAdoptedOrDeleted() throws {
    let (owner, directory) = try newOwner()
    XCTAssertTrue(prepare(owner))
    XCTAssertTrue(owner.prepareRuntimeDirectories())
    let codex = directory.appendingPathComponent("codex")
    try FileManager.default.moveItem(
      at: codex, to: fixture.appendingPathComponent("original-codex"))
    try makeDirectory(codex)
    let marker = codex.appendingPathComponent("unrelated")
    let bytes = Data("never adopt replacement".utf8)
    try bytes.write(to: marker)
    XCTAssertFalse(owner.prepareRuntimeDirectories())
    XCTAssertFalse(owner.cleanup())
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
  }

  func testReadOnlyValidationDoesNotRepairRemovedBackupExclusion() throws {
    let (owner, _) = try newOwner()
    let initialAttributes = try attributes(owner.descriptor)
    XCTAssertTrue(prepare(owner))
    let excludedAttributes = try attributes(owner.descriptor)
    let added = Set(excludedAttributes.keys).subtracting(initialAttributes.keys)
    XCTAssertEqual(added.count, 1)
    let addedName = try XCTUnwrap(added.first)
    // Physical fixture fault, using the observed added key without decoding it.
    // A Foundation setter/projection alone did not establish actual removal.
    XCTAssertEqual(fremovexattr(owner.descriptor, addedName, 0), 0)
    let removedAttributes = try attributes(owner.descriptor)
    XCTAssertNotEqual(removedAttributes, excludedAttributes)
    var before = stat()
    XCTAssertEqual(fstat(owner.descriptor, &before), 0)
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertEqual(try attributes(owner.descriptor), removedAttributes)
    var after = stat()
    XCTAssertEqual(fstat(owner.descriptor, &after), 0)
    XCTAssertEqual(after.st_ctimespec.tv_sec, before.st_ctimespec.tv_sec)
    XCTAssertEqual(after.st_ctimespec.tv_nsec, before.st_ctimespec.tv_nsec)
    XCTAssertFalse(prepare(owner))
    XCTAssertEqual(try attributes(owner.descriptor), removedAttributes)
  }

  func testWrongModeRefusalIsStickyDespiteExternalFixtureRepair() throws {
    let (owner, directory) = try newOwner()
    XCTAssertEqual(chmod(directory.path, 0o755), 0)
    XCTAssertFalse(prepare(owner))
    var info = stat()
    XCTAssertEqual(fstat(owner.descriptor, &info), 0)
    XCTAssertEqual(info.st_mode & 0o7777, 0o755)
    XCTAssertFalse(try excluded(directory))
    // Test-only external fault removal never grants the owner another attempt.
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    XCTAssertFalse(prepare(owner))
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertFalse(try excluded(directory))
  }

  func testReplacementDirectoryAndOriginalRemainUnmodified() throws {
    let (owner, directory) = try newOwner()
    let original = fixture.appendingPathComponent("moved-original", isDirectory: true)
    try FileManager.default.moveItem(at: directory, to: original)
    try makeDirectory(directory)
    let marker = directory.appendingPathComponent("unrelated-marker")
    let bytes = Data("private synthetic marker".utf8)
    try bytes.write(to: marker, options: .withoutOverwriting)
    XCTAssertFalse(prepare(owner))
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertFalse(try excluded(directory))
    XCTAssertFalse(try excluded(original))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
  }

  func testReplacementSymlinkCannotMarkItsTarget() throws {
    let (owner, directory) = try newOwner()
    let original = fixture.appendingPathComponent("moved-original", isDirectory: true)
    let unrelated = fixture.appendingPathComponent("unrelated", isDirectory: true)
    try FileManager.default.moveItem(at: directory, to: original)
    try makeDirectory(unrelated)
    let marker = unrelated.appendingPathComponent("marker")
    let bytes = Data("unrelated private fixture".utf8)
    try bytes.write(to: marker, options: .withoutOverwriting)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: unrelated)
    XCTAssertFalse(prepare(owner))
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertFalse(try excluded(unrelated))
    XCTAssertFalse(try excluded(original))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
  }

  func testCaptureTimeAncestorSwapCannotBindUnrelatedReference() throws {
    let id = UUID().uuidString.lowercased()
    let parent = fixture.appendingPathComponent("parent", isDirectory: true)
    let originalParent = fixture.appendingPathComponent("original-parent", isDirectory: true)
    let unrelatedParent = fixture.appendingPathComponent("unrelated-parent", isDirectory: true)
    let directory = parent.appendingPathComponent(id, isDirectory: true)
    let unrelatedDirectory = unrelatedParent.appendingPathComponent(id, isDirectory: true)
    let markerBytes = Data("unrelated capture-time fixture".utf8)
    try makeDirectory(parent)
    var captureError: Error?
    let hooks = TopologyOwnedFixtures.Hooks(captureReference: { _ in
      do {
        try FileManager.default.moveItem(at: parent, to: originalParent)
        try self.makeDirectory(parent)
        try self.makeDirectory(directory)
        try markerBytes.write(
          to: directory.appendingPathComponent("marker"), options: .withoutOverwriting)
        try FileManager.default.moveItem(at: parent, to: unrelatedParent)
        try FileManager.default.moveItem(at: originalParent, to: parent)
        return CFURLCreateFileReferenceURL(nil, unrelatedDirectory as CFURL, nil)?
          .takeRetainedValue()
      } catch {
        captureError = error
        return nil
      }
    })
    let owner = try XCTUnwrap(TopologyOwnedFixtures(root: parent, runID: id, hooks: hooks))
    if let captureError { throw captureError }
    XCTAssertFalse(prepare(owner))
    XCTAssertFalse(owner.hasBackupExclusion())
    XCTAssertFalse(try excluded(directory))
    XCTAssertFalse(try excluded(unrelatedDirectory))
    XCTAssertEqual(
      try Data(contentsOf: unrelatedDirectory.appendingPathComponent("marker")), markerBytes)
  }

  func testPreexistingNamespaceIsNeverAdoptedOrMarked() throws {
    let id = UUID().uuidString.lowercased()
    let directory = fixture.appendingPathComponent(id, isDirectory: true)
    try makeDirectory(directory)
    let marker = directory.appendingPathComponent("marker")
    let bytes = Data("existing private fixture".utf8)
    try bytes.write(to: marker, options: .withoutOverwriting)
    XCTAssertNil(TopologyOwnedFixtures(root: fixture, runID: id))
    XCTAssertFalse(try excluded(directory))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
  }

  func testCleanedNamespaceCannotAcquireBackupProof() throws {
    let (owner, directory) = try newOwner()
    XCTAssertTrue(owner.cleanup())
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertFalse(prepare(owner))
    XCTAssertFalse(owner.hasBackupExclusion())
  }

  func testUnknownMetadataChildBlocksExplicitCleanupAndNamespaceMutation() throws {
    let (namespace, directory) = try newOwner()
    let reference = try XCTUnwrap(
      CFURLCreateFileReferenceURL(nil, directory as CFURL, nil)?.takeRetainedValue())
    let gate = DispatchSemaphore(value: 0)
    let spawned = expectation(description: "actual metadata child spawned")
    let selected = expectation(description: "independent native deadline")
    let child = OwnedChildRetirement(
      backup: .init(
        namespace: namespace, interpreter: URL(fileURLWithPath: "/usr/bin/python3"),
        script: agentScript, reference: CFURLGetString(reference) as String),
      deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 300_000_000,
      hooks: .init(afterSpawn: { _ in
        spawned.fulfill()
        gate.wait()
      }))
    child.observeTerminal { _ in selected.fulfill() }
    child.retire()
    wait(for: [spawned, selected], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertTrue(child.testingChildExists)
    XCTAssertFalse(child.testingReaped)
    XCTAssertFalse(namespace.cleanup())
    XCTAssertFalse(namespace.create("M"))
    XCTAssertFalse(namespace.prepareLinks(["M"]))
    var before = stat()
    XCTAssertEqual(fstat(namespace.descriptor, &before), 0)
    var named = stat()
    XCTAssertEqual(
      fstatat(namespace.metadataParentDescriptor, namespace.runID, &named, AT_SYMLINK_NOFOLLOW), 0)
    XCTAssertEqual(named.st_ino, before.st_ino)
    XCTAssertEqual(named.st_dev, before.st_dev)
    gate.signal()
    let teardown = expectation(description: "fixture physical teardown only")
    child.testingPhysicalTeardown { _ in teardown.fulfill() }
    wait(for: [teardown], timeout: 1)
    XCTAssertEqual(child.terminal, .unknown(.deadline))
    XCTAssertTrue(child.testingRetained)
    XCTAssertFalse(namespace.permitsNamespaceMutation)
    XCTAssertFalse(namespace.cleanup())
  }
}
