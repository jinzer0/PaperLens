import Darwin
import Foundation
import SwiftUI

/// Explicit SQL diagnostic, never a product persistence owner or a P2 certificate.
enum SyntheticPackagedDBSmoke {
  static let flag = "--synthetic-packaged-db-smoke"
  enum Launch: Equatable { case absent, invalid, run(String) }
  enum Failure: Error { case ownership, deadline, report }
  enum Kind: String, Codable, CaseIterable, Sendable { case normal, m1, m2 }
  enum Phase: String, Codable, Sendable {
    case initial, base, migrations, fts, deletion, firstFailure, rollback
    case closeBeforeReopen, reopen, repeatedFailure, finalClose, cleanup
  }
  struct Check: Codable, Sendable {
    let phase: Phase
    let passed: Bool
  }
  struct SQLiteFailure: Codable, Sendable {
    let primary: Int32?
    let extended: Int32?
  }
  struct CaseResult: Codable, Sendable {
    let kind: Kind
    var checks: [Check] = []
    var failures: [SQLiteFailure] = []
    var reason: String?
    var passed: Bool {
      let expected: [Phase] = kind == .normal
        ? [.initial, .base, .migrations, .fts, .deletion, .closeBeforeReopen,
           .reopen, .finalClose, .cleanup]
        : [.initial, .firstFailure, .rollback, .closeBeforeReopen, .reopen,
           .repeatedFailure, .finalClose, .cleanup]
      return reason == nil && checks.map(\.phase) == expected
        && checks.allSatisfy(\.passed)
        && (kind == .normal ? failures.isEmpty : failures.count == 2)
    }
  }
  struct Report: Encodable, Sendable {
    let schema = "paperlens-synthetic-packaged-db-v1"
    let scope = "synthetic_sql_behavior_only"
    let sqliteOrigin = "sqlite_origin_unverified"
    let storyDone = false
    let p2Passed = false
    let runID: String
    let cases: [CaseResult]
    let behaviorPassed: Bool
    let cleanupConfirmed: Bool

    init(runID: String, cases: [CaseResult]) {
      self.runID = runID
      self.cases = cases
      behaviorPassed = cases.map(\.kind) == Kind.allCases && cases.allSatisfy(\.passed)
      cleanupConfirmed = cases.count == Kind.allCases.count
        && cases.allSatisfy { $0.checks.last?.phase == .cleanup && $0.checks.last?.passed == true }
    }
  }

  static func launch(_ arguments: [String]) -> Launch {
    guard arguments.dropFirst().contains(flag) else { return .absent }
    let args = Array(arguments.dropFirst())
    guard args.count == 3, args[0] == flag, args[1] == "--run-id",
      let id = UUID(uuidString: args[2]), id.uuidString.lowercased() == args[2]
    else { return .invalid }
    return .run(args[2])
  }

  static func run(parentURL: URL, runID: String) throws -> Report {
    let files = try SyntheticPackagedDBFiles(parentURL: parentURL, runID: runID)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var results: [CaseResult] = []
    for kind in Kind.allCases {
      guard ContinuousClock.now < deadline else { throw Failure.deadline }
      let result = execute(kind, files: files, deadline: deadline)
      results.append(result)
      // Never open a replacement after unconfirmed close or cleanup.
      guard result.checks.last?.phase == .cleanup, result.checks.last?.passed == true else { break }
    }
    let report = Report(runID: runID, cases: results)
    try files.write(report)
    return report
  }

  private static func execute(
    _ kind: Kind, files: SyntheticPackagedDBFiles, deadline: ContinuousClock.Instant
  ) -> CaseResult {
    var result = CaseResult(kind: kind)
    var probe: PackagedDBProbe?
    func check(_ phase: Phase, _ condition: Bool) throws {
      guard ContinuousClock.now < deadline else { throw Failure.deadline }
      result.checks.append(Check(phase: phase, passed: condition))
      guard condition else { throw PackagedDBFailure(.unexpectedFailure) }
    }
    func constraint(_ phase: Phase, _ probe: PackagedDBProbe) throws {
      var observed: PackagedDBFailure?
      do { _ = try probe.migrate() }
      catch { observed = error as? PackagedDBFailure }
      if let observed {
        result.failures.append(SQLiteFailure(primary: observed.primaryCode, extended: observed.extendedCode))
      }
      try check(phase, observed?.reason == .migrationFailed
        && observed?.primaryCode == 19 && observed?.extendedCode == 1555 && !probe.isReady)
    }
    do {
      let owner = try files.reserveCase()
      let fault: PackagedDBFault = kind == .normal ? .none : (kind == .m1 ? .m1 : .m2)
      let opened = try PackagedDBProbe(owner: owner, fault: fault)
      probe = opened
      let initial = try opened.snapshot()
      try check(.initial, initial.version == 0 && initial.migrations.isEmpty
        && initial.identifiers.isEmpty && initial.registryRows == 0
        && initial.probeObjects.isEmpty && initial.ftsRows == 0)
      if kind == .normal {
        let base = try opened.migrateBase()
        try check(.base, base.version == 1 && base.migrations == [PackagedDBProbe.migrationNames[0]]
          && base.registryRows == 1 && base.baseSchemaValid && base.baselineRows == 0)
        let full = try opened.migrate()
        try check(.migrations, full.version == 2 && full.migrations == PackagedDBProbe.migrationNames
          && full.identifiers == Set(PackagedDBProbe.migrationNames) && full.registryRows == 2
          && full.baseSchemaValid && full.ftsSchemaValid && opened.isReady)
        // Compare SQL text/content in RAM only; the report contains closed phase names and booleans.
        try check(.fts, full.ftsRows == 4 && full.ftsIDs == [1, 2, 3, 4]
          && full.sentences == PackagedDBProbe.corpus && full.matches == [1, 3])
        let deleted = try opened.deleteCorpus()
        try check(.deletion, deleted.ftsRows == 0 && deleted.sentences.isEmpty && deleted.matches.isEmpty)
        try check(.closeBeforeReopen, opened.closeAndDrain() && opened.hasObservedClose && owner.validate())
        try opened.reopen()
        let reopened = try opened.migrate()
        try check(.reopen, reopened == deleted && owner.validate() && opened.isReady
          && opened.failureHistory.isEmpty)
      } else {
        try constraint(.firstFailure, opened)
        let rolledBack = try opened.snapshot()
        let expectedMigrations = kind == .m1 ? [] : [PackagedDBProbe.migrationNames[0]]
        try check(.rollback, rolledBack.version == (kind == .m1 ? 0 : 1)
          && rolledBack.migrations == expectedMigrations
          && rolledBack.identifiers == Set(expectedMigrations)
          && rolledBack.registryRows == expectedMigrations.count
          && rolledBack.probeObjects == (kind == .m1 ? [] : ["probe_base"])
          && rolledBack.baselineRows == 0 && rolledBack.ftsRows == 0
          && !rolledBack.ftsSchemaValid && rolledBack.sentences.isEmpty && rolledBack.matches.isEmpty
          && (kind == .m1 || rolledBack.baseSchemaValid))
        try check(.closeBeforeReopen, opened.closeAndDrain() && opened.hasObservedClose && owner.validate())
        try opened.reopen()
        let reopened = try opened.snapshot()
        try check(.reopen, reopened == rolledBack && owner.validate() && !opened.isReady)
        try constraint(.repeatedFailure, opened)
        let repeated = try opened.snapshot()
        guard repeated == rolledBack && opened.failureHistory.count == 2
          && opened.failureHistory.allSatisfy({
            $0.reason == .migrationFailed && $0.primaryCode == 19 && $0.extendedCode == 1555
          })
        else { throw PackagedDBFailure(.unexpectedFailure) }
      }
    } catch {
      if let failure = error as? PackagedDBFailure { result.reason = failure.reason.rawValue }
      else if case Failure.deadline = error { result.reason = "deadline_exceeded" }
      else { result.reason = "binding_mismatch" }
    }
    if let probe {
      let closed = probe.closeAndDrain() && probe.hasObservedClose
      result.checks.append(Check(phase: .finalClose, passed: closed))
      let cleaned = closed && probe.cleanup()
      result.checks.append(Check(phase: .cleanup, passed: cleaned))
      if !cleaned && result.reason == nil { result.reason = PackagedDBReason.cleanupFailed.rawValue }
    }
    if ContinuousClock.now >= deadline && result.reason == nil { result.reason = "deadline_exceeded" }
    return result
  }
}

/// Only fresh, descriptor-bound diagnostic artifacts. No recursive cleanup or adoption.
final class SyntheticPackagedDBFiles {
  let root: URL
  private let parentURL: URL
  private let runID: String
  private let parent: Int32
  private let directory: Int32
  private let build: Int32
  private let topology: Int32
  private let parentInfo: stat
  private let rootInfo: stat
  private let buildInfo: stat
  private let topologyInfo: stat
  private var namespaces: [Int32] = []

  init(parentURL: URL, runID: String) throws {
    guard parentURL.isFileURL, parentURL.standardizedFileURL == parentURL,
      let id = UUID(uuidString: runID), id.uuidString.lowercased() == runID
    else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    var descriptors: [Int32] = []
    var complete = false
    defer { if !complete { descriptors.forEach { Darwin.close($0) } } }
    guard let parent = TopologyFixtures.directory(parentURL, create: true) else {
      throw SyntheticPackagedDBSmoke.Failure.ownership
    }
    descriptors.append(parent)
    var parentInfo = stat()
    guard TopologyFixtures.privateDirectory(parent, info: &parentInfo),
      mkdirat(parent, runID, 0o700) == 0 else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    func freshDirectory(_ parent: Int32, _ name: String, create: Bool = true) throws -> (Int32, stat) {
      if create, mkdirat(parent, name, 0o700) != 0 { throw SyntheticPackagedDBSmoke.Failure.ownership }
      let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw SyntheticPackagedDBSmoke.Failure.ownership }
      descriptors.append(fd)
      var info = stat()
      guard TopologyFixtures.privateDirectory(fd, info: &info),
        TopologyFixtures.matches(directory: parent, name: name, info: info)
      else { throw SyntheticPackagedDBSmoke.Failure.ownership }
      return (fd, info)
    }
    let (directory, rootInfo) = try freshDirectory(parent, runID, create: false)
    let (build, buildInfo) = try freshDirectory(directory, ".build")
    let (topology, topologyInfo) = try freshDirectory(build, "topology")
    self.parentURL = parentURL
    self.runID = runID
    root = parentURL.appendingPathComponent(runID, isDirectory: true)
    self.parent = parent; self.parentInfo = parentInfo
    self.directory = directory; self.rootInfo = rootInfo
    self.build = build; self.buildInfo = buildInfo
    self.topology = topology; self.topologyInfo = topologyInfo
    complete = true
    guard validate() else { throw SyntheticPackagedDBSmoke.Failure.ownership }
  }

  private func validate() -> Bool {
    func same(_ fd: Int32, _ expected: stat) -> Bool {
      var current = stat()
      return TopologyFixtures.privateDirectory(fd, info: &current)
        && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
    }
    guard same(parent, parentInfo), same(directory, rootInfo), same(build, buildInfo),
      same(topology, topologyInfo),
      TopologyFixtures.matches(directory: parent, name: runID, info: rootInfo),
      TopologyFixtures.matches(directory: directory, name: ".build", info: buildInfo),
      TopologyFixtures.matches(directory: build, name: "topology", info: topologyInfo),
      let current = TopologyFixtures.directory(parentURL, create: false) else { return false }
    defer { Darwin.close(current) }
    return same(current, parentInfo)
  }

  func reserveCase() throws -> TopologyDBOwnerContext {
    guard validate() else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    let id = UUID().uuidString.lowercased()
    let entry = "local-grdb-probe-" + id
    guard mkdirat(topology, entry, 0o700) == 0 else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    let namespace = openat(topology, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard namespace >= 0 else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    namespaces.append(namespace)
    let reservation = openat(namespace, "db.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard reservation >= 0 else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    var namespaceInfo = stat()
    var databaseInfo = stat()
    let valid = TopologyFixtures.privateDirectory(namespace, info: &namespaceInfo)
      && TopologyFixtures.privateFile(reservation, info: &databaseInfo) && databaseInfo.st_size == 0
      && TopologyFixtures.matches(directory: topology, name: entry, info: namespaceInfo)
      && TopologyFixtures.matches(directory: namespace, name: "db.sqlite", info: databaseInfo)
    // Close the reservation before SQLite opens: no auxiliary DB descriptors while SQL is live.
    let closed = Darwin.close(reservation) == 0
    guard valid, closed, validate() else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    let owner = TopologyDBOwnerContext(worktreePath: root.path, worktree: directory,
      topology: topology, namespace: namespace, worktreeIdentity: rootInfo,
      topologyIdentity: topologyInfo, namespaceIdentity: namespaceInfo, databaseIdentity: databaseInfo,
      uid: getuid(), ownerID: runID, runID: id, attemptID: UUID().uuidString.lowercased())
    guard owner.validate(), owner.entries() == ["db.sqlite"] else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    return owner
  }

  func write(_ report: SyntheticPackagedDBSmoke.Report) throws {
    guard validate(), report.runID == runID else { throw SyntheticPackagedDBSmoke.Failure.ownership }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(report)
    guard !bytes.isEmpty, bytes.count <= 16_384 else { throw SyntheticPackagedDBSmoke.Failure.report }
    let fd = openat(directory, "report.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SyntheticPackagedDBSmoke.Failure.report }
    var descriptorOpen = true
    defer { if descriptorOpen { Darwin.close(fd) } }
    var info = stat()
    guard TopologyFixtures.privateFile(fd, info: &info),
      TopologyFixtures.matches(directory: directory, name: "report.json", info: info)
    else { throw SyntheticPackagedDBSmoke.Failure.report }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SyntheticPackagedDBSmoke.Failure.report }
        offset += count
      }
    }
    var current = stat()
    guard TopologyFixtures.sync(fd), TopologyFixtures.privateFile(fd, info: &current),
      current.st_dev == info.st_dev, current.st_ino == info.st_ino,
      current.st_size == bytes.count, validate(),
      TopologyFixtures.matches(directory: directory, name: "report.json", info: info)
    else { throw SyntheticPackagedDBSmoke.Failure.report }
    let closed = Darwin.close(fd) == 0
    descriptorOpen = false
    guard closed, TopologyFixtures.sync(directory), validate(),
      TopologyFixtures.privateNamedFile(directory: directory, name: "report.json",
        path: root.appendingPathComponent("report.json").path, info: &current),
      current.st_size == bytes.count,
      TopologyFixtures.matches(directory: directory, name: "report.json", info: info)
    else { throw SyntheticPackagedDBSmoke.Failure.report }
  }

  deinit {
    namespaces.forEach { Darwin.close($0) }
    [topology, build, directory, parent].forEach { Darwin.close($0) }
  }
}

@MainActor final class SyntheticPackagedDBSmokeModel: ObservableObject {
  @Published private(set) var status = "합성 DB 진단 준비 중"
  @Published private(set) var running = false
  private var started = false
  private var timedOut = false
  func start(arguments: [String]) {
    guard !started else { return }
    started = true
    guard case .run(let id) = SyntheticPackagedDBSmoke.launch(arguments),
      Bundle.main.bundleIdentifier == TopologyIdentity.main,
      let container = TopologyIdentity.container(TopologyIdentity.main) else {
      status = "합성 DB 진단 시작 실패 · 실행 인자 또는 전용 앱 컨테이너를 확인하세요."
      return
    }
    running = true
    status = "마이그레이션·FTS·롤백·같은 파일 재열기 검사 중"
    let parent = container.appendingPathComponent("Library/Application Support/PaperLensSyntheticPackagedDB", isDirectory: true)
    Task {
      try? await Task.sleep(for: .seconds(30))
      if running {
        timedOut = true
        status = "합성 DB 검사 시간 초과 · 실제 종료와 정리 확인 전에는 새 검사를 시작하지 않습니다."
      }
    }
    Task {
      let passed = await Task.detached(priority: .utility) {
        do {
          let report = try SyntheticPackagedDBSmoke.run(parentURL: parent, runID: id)
          return report.behaviorPassed && report.cleanupConfirmed
        } catch { return false }
      }.value
      running = false
      status = passed && !timedOut
        ? "합성 DB 검사 통과 · 정상·M1 실패·M2 실패의 재열기와 정리 확인"
        : "합성 DB 검사 실패 · 기존 run과 소유권이 불명확한 파일은 보존합니다."
    }
  }
}

@MainActor struct SyntheticPackagedDBSmokeView: View {
  @ObservedObject var model: SyntheticPackagedDBSmokeModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("합성 DB 진단").font(.title)
      Text(model.status)
      if model.running { ProgressView() }
      Text("전용 합성 저장소에서 SQL 동작을 검사합니다. SQLite 출처 및 전체 OS 검증 완료를 뜻하지 않습니다.")
        .font(.caption)
    }.padding(24).frame(minWidth: 620, minHeight: 220)
  }
}
