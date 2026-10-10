import CryptoKit
import Darwin
import Foundation
#if SWIFT_PACKAGE
import ProviderRequest
#endif

public enum URLImportError: Error, Equatable, Sendable {
  case rejected, capacity, cancelled, writerUnavailable, closureUnknown, cleanupFailed
}

/// Created only after the actual file producer and URLSession have closed/drained.
public struct ClosedHTTPSPDFStage: Sendable {
  public let file: URL
  public let sha256: String
  public let byteCount: Int
  fileprivate init(file: URL, sha256: String, byteCount: Int) {
    self.file = file
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

struct HTTPSPDFFileEffects: Sendable {
  let acquired: @Sendable (Int32) -> Void
  let checkedClose: @Sendable (FileHandle) throws -> Void
  let sessionStarted: @Sendable (URLSession) -> Void
  let finalNetworkDrain: @Sendable () -> Void
  static let actual = HTTPSPDFFileEffects(acquired: { _ in },
    checkedClose: { try $0.close() }, sessionStarted: { _ in }, finalNetworkDrain: {})
}

private final class HTTPSPDFProducerRoots: @unchecked Sendable {
  static let shared = HTTPSPDFProducerRoots()
  private let lock = NSLock()
  private var producers: [UUID: HTTPSPDFProducer] = [:]
  func retain(_ producer: HTTPSPDFProducer) {
    lock.withLock { producers[producer.id] = producer }
  }
  func release(_ id: UUID) {
    let removed = lock.withLock { producers.removeValue(forKey: id) }
    withExtendedLifetime(removed) {} // Destruction is outside the registry lock.
  }
  var ids: Set<UUID> { lock.withLock { Set(producers.keys) } }
}

public final class HTTPSPDFImportAdapter: Sendable {
  static var rootedProducerIDs: Set<UUID> { HTTPSPDFProducerRoots.shared.ids }
  private let authority: ProviderRequest
  public init(authority: ProviderRequest) { self.authority = authority }

  public func route(_ text: String) throws -> ValidatedRequestURL {
    if let abstract = try? authority.resolveArxivAbstractURL(text) { return abstract }
    if let pdf = try? authority.validateImportURL(text, sourceKind: "arxivPDF") { return pdf }
    if let host = URLComponents(string: text)?.host?.lowercased(),
      authority.contract["policies"]["arxivHosts"].array.contains(.string(host)) {
      throw URLImportError.rejected
    }
    return try authority.validateImportURL(text, sourceKind: "httpsPDF")
  }

  public func download(
    route: ValidatedRequestURL, stagingDirectory: URL,
    assertCurrent: @escaping @Sendable () throws -> Void
  ) async throws -> ClosedHTTPSPDFStage {
    try await download(route: route, stagingDirectory: stagingDirectory,
      assertCurrent: assertCurrent, configuration: .ephemeral, effects: .actual)
  }

  // Configuration injection is internal and used only for deterministic URLProtocol tests.
  func download(
    route: ValidatedRequestURL, stagingDirectory: URL,
    assertCurrent: @escaping @Sendable () throws -> Void,
    configuration: URLSessionConfiguration, effects: HTTPSPDFFileEffects
  ) async throws -> ClosedHTTPSPDFStage {
    try Task.checkCancellation()
    try assertCurrent()
    let validated = try authority.validateImportURL(route.value, sourceKind: route.sourceKind)
    let decodedPath = stagingDirectory.path(percentEncoded: false)
    guard stagingDirectory.isFileURL, decodedPath.hasPrefix("/"), !decodedPath.utf8.contains(0),
      stagingDirectory.withUnsafeFileSystemRepresentation({ $0 != nil }) else {
      throw URLImportError.writerUnavailable
    }
    let values: URLResourceValues
    do {
      values = try stagingDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch { throw URLImportError.writerUnavailable }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw URLImportError.writerUnavailable
    }
    let budget = try RequestResourceBudget(authority: authority, kind: "import")
    let pool = try RequestResourcePool(authority: authority, kind: "import")
    guard let lease = pool.acquire() else { throw URLImportError.capacity }
    let producer = HTTPSPDFProducer(authority: authority, route: validated,
      directory: stagingDirectory, assertCurrent: assertCurrent, budget: budget,
      lease: lease, effects: effects)
    HTTPSPDFProducerRoots.shared.retain(producer)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        producer.start(configuration: configuration, continuation: continuation)
      }
    } onCancel: { producer.cancel() }
  }
}

private final class HTTPSPDFProducer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let id = UUID()
  private let lease: RequestResourceLease
  private let effects: HTTPSPDFFileEffects
  private var closeAttempted = false
  private var fileClosed = false
  private var finished = false
  private let authority: ProviderRequest
  private let budget: RequestResourceBudget
  private let assertCurrent: @Sendable () throws -> Void
  private let queue = DispatchQueue(label: "PaperLens.HTTPSPDFProducer")
  private let clock = ContinuousClock()
  private let started: ContinuousClock.Instant
  private var lastActivity: ContinuousClock.Instant
  private var route: ValidatedRequestURL
  private var nextRoute: ValidatedRequestURL?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var timer: DispatchSourceTimer?
  private var continuation: CheckedContinuation<ClosedHTTPSPDFStage, any Error>?
  private var output: FileHandle?
  private let stage: URL
  private var digest = SHA256()
  private var bytes = 0
  private var prefix = Data()
  private var responseHeaders: [RequestHTTPHeader] = []
  private var responseStatus = 0
  private var admitted = false
  private var failure: URLImportError?
  private var cancelled = false
  private var bodyComplete = false

  init(authority: ProviderRequest, route: ValidatedRequestURL, directory: URL,
    assertCurrent: @escaping @Sendable () throws -> Void, budget: RequestResourceBudget,
    lease: RequestResourceLease, effects: HTTPSPDFFileEffects) {
    self.authority = authority
    self.route = route
    self.assertCurrent = assertCurrent
    self.budget = budget
    self.lease = lease
    self.effects = effects
    started = clock.now
    lastActivity = started
    stage = directory.appendingPathComponent(UUID().uuidString + ".pdf")
    super.init()
  }

  func start(configuration: URLSessionConfiguration,
    continuation: CheckedContinuation<ClosedHTTPSPDFStage, any Error>) {
    queue.async {
      self.continuation = continuation
      // Rooted producer owns the admitted lease before any FD or session effects.
      let descriptor = self.stage.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
      }
      guard descriptor >= 0 else {
        self.fileClosed = true // No descriptor was ever acquired.
        self.failure = .writerUnavailable
        self.finish(removeStage: false)
        return
      }
      self.output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      self.effects.acquired(descriptor)
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.timeoutIntervalForRequest = Double(self.authority.limit("idleMs")) / 1000
      configuration.timeoutIntervalForResource = Double(self.authority.limit("importElapsedMs")) / 1000
      let delegates = OperationQueue()
      delegates.maxConcurrentOperationCount = 1
      delegates.underlyingQueue = self.queue
      self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      self.timer = timer
      let interval = self.authority.limit("watchdogIntervalMs")
      timer.schedule(deadline: .now(), repeating: .milliseconds(interval))
      timer.setEventHandler { [weak self = self] in
        guard let self else { return }
        do { try self.check() } catch { self.fail(.rejected) }
      }
      timer.resume()
      if self.cancelled { self.fail(.cancelled) } else { self.request() }
      if let session = self.session { self.effects.sessionStarted(session) }
    }
  }

  func cancel() {
    queue.async {
      guard !self.finished else { return }
      self.cancelled = true
      if self.failure == nil { self.failure = .cancelled }
      self.timer?.cancel()
      self.session?.invalidateAndCancel()
    }
  }

  private func milliseconds(_ instant: ContinuousClock.Instant) -> Int {
    let duration = instant.duration(to: clock.now).components
    return Int(duration.seconds) * 1000 + Int(duration.attoseconds / 1_000_000_000_000_000)
  }

  private func check() throws {
    guard failure == nil, !cancelled, !closeAttempted, !finished else { throw URLImportError.cancelled }
    try assertCurrent()
    try budget.observe("elapsedMs", value: milliseconds(started))
    try budget.observe("idleMs", value: milliseconds(lastActivity))
  }

  private func request() {
    do {
      try check()
      guard let url = URL(string: route.value) else { throw URLImportError.rejected }
      var request = URLRequest(url: url)
      request.setValue(authority.contract["policies"]["encoding"].string, forHTTPHeaderField: "Accept-Encoding")
      request.setValue(authority.contract["policies"]["pdfMIME"].string, forHTTPHeaderField: "Accept")
      task = session?.dataTask(with: request)
      task?.resume()
    } catch { fail(.rejected) }
  }

  private func headers(_ response: HTTPURLResponse) -> [RequestHTTPHeader] {
    response.allHeaderFields.map { RequestHTTPHeader(String(describing: $0.key), String(describing: $0.value)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    guard !finished, !closeAttempted else { completionHandler(nil); return }
    do {
      try check()
      let admission = try authority.validateHTTPResponse(current: route,
        status: response.statusCode, headers: headers(response), prefix: Data(), budget: budget)
      guard case .redirect(let target) = admission else { throw URLImportError.rejected }
      nextRoute = target
      lastActivity = clock.now
    } catch { failure = .rejected }
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard !finished, !closeAttempted else { completionHandler(.cancel); return }
    do {
      try check()
      guard let http = response as? HTTPURLResponse else { throw URLImportError.rejected }
      lastActivity = clock.now
      if nextRoute != nil { completionHandler(.allow); return }
      responseHeaders = headers(http)
      responseStatus = http.statusCode
      // Header/status admission is provisional; the real body signature must also pass.
      let admission = try authority.validateHTTPResponse(current: route, status: responseStatus,
        headers: responseHeaders,
        prefix: Data(authority.contract["policies"]["pdfMagic"].string.utf8), budget: budget)
      guard case .pdf = admission else { throw URLImportError.rejected }
      completionHandler(.allow)
    } catch { completionHandler(.cancel); fail(.rejected) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !finished, !closeAttempted else { return }
    do {
      try check()
      try budget.observe("readBufferBytes", value: data.count)
      try budget.add("bodyBytes", delta: data.count)
      lastActivity = clock.now
      if nextRoute != nil { return } // Redirect body counts but is never written.
      if !admitted {
        let magicCount = authority.contract["policies"]["pdfMagic"].string.utf8.count
        let needed = magicCount - prefix.count
        prefix.append(data.prefix(needed))
        if prefix.count == magicCount {
          try authority.validatePDFSignature(prefix: prefix,
            mime: authority.contract["policies"]["pdfMIME"].string, sourceKind: route.sourceKind)
          admitted = true
        }
      }
      try output?.write(contentsOf: data)
      digest.update(data: data)
      bytes += data.count
    } catch { fail(.rejected) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard !finished, !closeAttempted else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      fail(.rejected)
    }
  }

  private func fail(_ error: URLImportError) {
    guard !finished, !closeAttempted else { return }
    if failure == nil { failure = error }
    timer?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard !closeAttempted, !finished else { return }
    if failure == nil, error == nil, let target = nextRoute {
      nextRoute = nil
      route = target
      request()
      return
    }
    if error != nil, failure == nil { failure = cancelled ? .cancelled : .rejected }
    do {
      try check()
      guard admitted, bytes > 0, let output else { throw URLImportError.rejected }
      try output.synchronize()
      guard Darwin.fchmod(output.fileDescriptor, mode_t(0o400)) == 0 else {
        throw URLImportError.rejected
      }
    } catch { if failure == nil { failure = .rejected } }
    closeFileOnce()
    if failure == nil { bodyComplete = true }
    timer?.cancel()
    session.finishTasksAndInvalidate()
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    guard !finished else { return }
    timer?.cancel()
    // Invalidation is the final network producer drain, not merely task cancellation.
    closeFileOnce()
    effects.finalNetworkDrain()
    if error != nil, failure == nil { failure = .rejected }
    finish(removeStage: true)
  }

  private func closeFileOnce() {
    guard !closeAttempted else { return }
    closeAttempted = true
    guard let output else { return }
    do {
      try effects.checkedClose(output)
      fileClosed = true
      self.output = nil
    } catch { failure = .closureUnknown }
  }

  private func finish(removeStage: Bool) {
    finished = true
    if !fileClosed { failure = .closureUnknown }
    if failure != nil || !bodyComplete {
      if removeStage, fileClosed {
        do { try FileManager.default.removeItem(at: stage) }
        catch { failure = .cleanupFailed }
      }
    }
    // Known file close plus final session drain, or setup without acquiring an FD.
    // Unknown output and quota remain rooted even after the continuation returns.
    if fileClosed {
      lease.close()
      HTTPSPDFProducerRoots.shared.release(id)
    }
    if failure != nil || !bodyComplete {
      continuation?.resume(throwing: failure ?? URLImportError.rejected)
    } else {
      let result = ClosedHTTPSPDFStage(file: stage,
        sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: bytes)
      continuation?.resume(returning: result)
    }
    continuation = nil
    self.session = nil
  }
}
