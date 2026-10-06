import Darwin
import Foundation

@_silgen_name("FPDF_InitLibrary") private func FPDF_InitLibrary()
@_silgen_name("FPDF_DestroyLibrary") private func FPDF_DestroyLibrary()

private final class PDFService: NSObject, PDFTopologyService, @unchecked Sendable {
  private static let queue = DispatchQueue(label: "PaperLens.PDFium.topology")
  private let lock = NSLock()
  private var accepted = false
  private var identified = false
  private var identifiedRun: String?

  func identify(_ runID: String, withReply reply: @escaping (Data) -> Void) {
    lock.lock()
    let permitted =
      !identified && !accepted && TopologyFixtures.validRunID(runID)
      && TopologyFixtures.profileMatches(TopologyIdentity.worker)
    identified = true
    identifiedRun = permitted ? runID : nil
    lock.unlock()
    guard permitted else {
      reply(TopologyFixtures.json(["status": "blocked"]))
      return
    }
    // This method activates/binds the live peer, but never initializes
    // PDFium, accepts a descriptor, or performs a file/network probe.
    reply(TopologyFixtures.json(["runID": runID, "pid": Int(getpid())]))
  }

  func inspect(_ runID: String, pdf: FileHandle, withReply reply: @escaping (Data) -> Void) {
    // Only one bounded inspection per connection; never queue unbounded FDs.
    lock.lock()
    let permitted = !accepted && identifiedRun == runID && TopologyFixtures.validRunID(runID)
    accepted = true
    lock.unlock()
    guard permitted else {
      try? pdf.close()
      reply(TopologyFixtures.json(["status": "failed"]))
      return
    }
    let work = Inspection(runID: runID, pdf: pdf, reply: reply)
    Self.queue.async { self.inspect(work) }
  }

  private final class Inspection: @unchecked Sendable {
    let runID: String
    let pdf: FileHandle
    let reply: (Data) -> Void
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    var own: TopologyOwnedFixtures?
    var cases: [[String: Any]] = []
    var initialized = false
    var finished = false
    init(runID: String, pdf: FileHandle, reply: @escaping (Data) -> Void) {
      self.runID = runID
      self.pdf = pdf
      self.reply = reply
    }
  }

  private func inspect(_ work: Inspection) {
    let matched = TopologyFixtures.profileMatches(TopologyIdentity.worker)
    guard matched, DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: false)
      return
    }
    let root = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/PaperLensTopology")
    guard let own = TopologyOwnedFixtures(root: root, runID: work.runID),
      own.prepareLinks(["M", "A", "C", "E", "G"]), own.checkLinks()
    else {
      finish(work, status: "blocked", matched: true)
      return
    }
    work.own = own
    Self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: work.deadline)) {
      self.finish(work, status: "blocked", matched: true)
    }
    fence(work, phase: "pre")
  }

  private func fence(_ work: Inspection, phase: String) {
    guard !work.finished, let own = work.own,
      DispatchTime.now().uptimeNanoseconds < work.deadline
    else {
      finish(work, status: "blocked", matched: true)
      return
    }
    let intervals: [[String: Any]] =
      phase == "post"
      ? work.cases.compactMap { row in
        guard row["syscallObserved"] as? Bool == true,
          let id = row["caseID"] as? String,
          let began = row["beganAtNs"] as? Int64, let ended = row["endedAtNs"] as? Int64
        else { return nil }
        return ["caseID": id, "beganAtNs": began, "endedAtNs": ended]
      } : []
    let now = DispatchTime.now().uptimeNanoseconds
    let remaining = work.deadline > now ? Int((work.deadline - now) / 1_000_000) : 0
    guard remaining > 0 else {
      finish(work, status: "blocked", matched: true)
      return
    }
    TopologyReadiness.fence(
      directory: own.descriptor, runID: work.runID, phase: phase,
      actors: [["role": "PDFiumXPC", "pid": Int(getpid())]],
      links: own.links, intervals: intervals, ownerControl: own.checkLinks(),
      timeoutMs: min(2000, remaining)
    ) { accepted in
      Self.queue.async {
        guard !work.finished else { return }
        guard accepted, DispatchTime.now().uptimeNanoseconds < work.deadline else {
          self.finish(work, status: "blocked", matched: true)
          return
        }
        if phase == "pre" {
          self.probes(work)
        } else {
          self.finish(work, status: "inconclusive", matched: true)
        }
      }
    }
  }

  private func probes(_ work: Inspection) {
    guard !work.finished, DispatchTime.now().uptimeNanoseconds < work.deadline else { return }
    FPDF_InitLibrary()
    defer { FPDF_DestroyLibrary() }
    work.initialized = true
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: true)
      return
    }
    var cases: [[String: Any]] = []
    let fd = work.pdf.fileDescriptor
    var info = stat()
    var bytes = [UInt8](repeating: 0, count: 4096)
    let validFile =
      fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 4096
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      finish(work, status: "blocked", matched: true)
      return
    }
    let readStart = Int64(DispatchTime.now().uptimeNanoseconds)
    let count = validFile ? pread(fd, &bytes, bytes.count, 0) : 0
    let readError = validFile && count < 0 ? errno : 0
    let readEnd = Int64(DispatchTime.now().uptimeNanoseconds)
    let expected = TopologyFixtures.marker("PDF", runID: work.runID)
    var readCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorRead", result: count, error: readError, matched: validFile,
      observed: validFile, beganAtNs: validFile ? readStart : 0,
      endedAtNs: validFile ? readEnd : 0)
    readCase["verdict"] =
      count == expected.count && Data(bytes.prefix(max(0, count))) == expected ? "pass" : "failed"
    cases.append(readCase)
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      work.cases = cases
      finish(work, status: "blocked", matched: true)
      return
    }
    var byte = expected.first!
    let writeStart = Int64(DispatchTime.now().uptimeNanoseconds)
    let written = validFile ? pwrite(fd, &byte, 1, 0) : 0
    let writeError = written < 0 ? errno : 0
    let writeEnd = Int64(DispatchTime.now().uptimeNanoseconds)
    var writeCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorWrite", result: written, error: writeError, matched: validFile,
      observed: validFile, beganAtNs: validFile ? writeStart : 0,
      endedAtNs: validFile ? writeEnd : 0)
    // EBADF establishes only the read-only descriptor capability, not sandbox denial.
    writeCase["verdict"] = written < 0 && writeError == EBADF ? "pass" : "failed"
    cases.append(writeCase)
    guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
      work.cases = cases
      finish(work, status: "blocked", matched: true)
      return
    }
    cases.append(
      TopologyFixtures.probe(
        runID: work.runID, actor: "PDFiumXPC", alias: "PDF", operation: "write"))
    for alias in ["M", "A", "C", "E", "G"] {
      for operation in ["read", "write", "symlinkRead"] {
        guard DispatchTime.now().uptimeNanoseconds < work.deadline else {
          work.cases = cases
          finish(work, status: "blocked", matched: true)
          return
        }
        cases.append(
          TopologyFixtures.probe(
            runID: work.runID, actor: "PDFiumXPC", alias: alias,
            operation: operation, symlinkDirectory: work.own?.descriptor))
      }
    }
    if work.deadline - min(work.deadline, DispatchTime.now().uptimeNanoseconds) >= 2_000_000_000 {
      cases.append(
        TopologyFixtures.network(runID: work.runID, actor: "PDFiumXPC", expectAllowed: false))
    } else {
      cases.append(
        TopologyFixtures.observation(
          runID: work.runID, actor: "PDFiumXPC", alias: "network", operation: "connect",
          result: 0, matched: false))
    }
    work.cases = cases
    fence(work, phase: "post")
  }

  private func finish(_ work: Inspection, status: String, matched: Bool) {
    guard !work.finished else { return }
    work.finished = true
    let cleaned = work.own?.cleanup() ?? true
    work.own = nil
    try? work.pdf.close()
    work.reply(
      TopologyFixtures.json([
        "status": cleaned ? status : "failed", "pdfiumInitialized": work.initialized,
        "expectedRootMatched": matched, "cases": work.cases,
      ]))
  }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.setCodeSigningRequirement(TopologyIdentity.requirement(TopologyIdentity.main))
    connection.exportedInterface = NSXPCInterface(with: PDFTopologyService.self)
    connection.exportedObject = PDFService()
    connection.resume()
    return true
  }
}

@main
private enum PDFiumServiceMain {
  static func main() {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) {
      listener.resume()
    }
  }
}
