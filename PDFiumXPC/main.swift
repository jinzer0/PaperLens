import Darwin
import Foundation

@_silgen_name("FPDF_InitLibrary") private func FPDF_InitLibrary()
@_silgen_name("FPDF_DestroyLibrary") private func FPDF_DestroyLibrary()

private final class PDFService: NSObject, PDFTopologyService, @unchecked Sendable {
  private static let queue = DispatchQueue(label: "PaperLens.PDFium.topology")
  private let lock = NSLock()
  private var accepted = false

  func inspect(_ runID: String, pdf: FileHandle, withReply reply: @escaping (Data) -> Void) {
    // Only one bounded inspection per connection; never queue unbounded FDs.
    lock.lock()
    let permitted = !accepted && TopologyFixtures.validRunID(runID)
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
    init(runID: String, pdf: FileHandle, reply: @escaping (Data) -> Void) {
      self.runID = runID
      self.pdf = pdf
      self.reply = reply
    }
  }

  private func inspect(_ work: Inspection) {
    defer { try? work.pdf.close() }
    FPDF_InitLibrary()
    defer { FPDF_DestroyLibrary() }
    let matched = TopologyFixtures.profileMatches(TopologyIdentity.worker)
    guard matched else {
      work.reply(
        TopologyFixtures.json([
          "status": "blocked", "pdfiumInitialized": true,
          "expectedRootMatched": false, "cases": [],
        ]))
      return
    }
    let root = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/PaperLensTopology")
    let own = TopologyOwnedFixtures(root: root, runID: work.runID)
    defer { own?.cleanup() }
    var cases: [[String: Any]] = []
    let fd = work.pdf.fileDescriptor
    var info = stat()
    var bytes = [UInt8](repeating: 0, count: 4096)
    let validFile =
      fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 4096
    let count = validFile ? pread(fd, &bytes, bytes.count, 0) : -1
    let readError = validFile && count < 0 ? errno : 0
    let expected = TopologyFixtures.marker("PDF", runID: work.runID)
    var readCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorRead", result: count, error: readError)
    readCase["verdict"] =
      count == expected.count && Data(bytes.prefix(max(0, count))) == expected ? "pass" : "failed"
    cases.append(readCase)
    var byte = expected.first!
    let written = pwrite(fd, &byte, 1, 0)
    let writeError = written < 0 ? errno : 0
    var writeCase = TopologyFixtures.observation(
      runID: work.runID, actor: "PDFiumXPC", alias: "PDF",
      operation: "descriptorWrite", result: written, error: writeError)
    // EBADF establishes only the read-only descriptor capability, not sandbox denial.
    writeCase["verdict"] = written < 0 && writeError == EBADF ? "pass" : "failed"
    cases.append(writeCase)
    cases.append(
      TopologyFixtures.probe(
        runID: work.runID, actor: "PDFiumXPC", alias: "PDF", operation: "write"))
    for alias in ["M", "A", "C", "E", "G"] {
      for operation in ["read", "write", "symlinkRead"] {
        cases.append(
          TopologyFixtures.probe(
            runID: work.runID, actor: "PDFiumXPC", alias: alias,
            operation: operation, symlinkDirectory: own?.descriptor))
      }
    }
    cases.append(
      TopologyFixtures.network(runID: work.runID, actor: "PDFiumXPC", expectAllowed: false))
    work.reply(
      TopologyFixtures.json([
        "status": "inconclusive", "pdfiumInitialized": true,
        "expectedRootMatched": true, "cases": cases,
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
