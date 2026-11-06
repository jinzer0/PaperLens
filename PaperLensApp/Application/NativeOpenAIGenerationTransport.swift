import Foundation

#if SWIFT_PACKAGE
  import ProviderRequest
#endif

/// HTTP execution only. Model/profile admission belongs to the caller and shared authority;
/// a successful HTTP response is not certification of tokenizer or hidden-control bounds.
@MainActor
public protocol NativeGenerationTransport {
  func execute(
    key: String, configuration: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest
  ) async throws -> ValidatedProviderResult
}

internal enum NativeHTTPLifecycleEvent: Equatable, Sendable {
  case taskCompleted, sessionInvalidated, consumerDrained
}

@MainActor
public final class URLSessionOpenAIGenerationTransport: NativeGenerationTransport {
  private let configuration: URLSessionConfiguration
  private let deadlineCapMilliseconds: Int?
  private let observe: (@Sendable (NativeHTTPLifecycleEvent) -> Void)?

  public init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    deadlineCapMilliseconds = nil
    observe = nil
  }

  /// Deterministic tests may shorten, never enlarge, the shared deadline and observe
  /// actual delegate callbacks. Neither input grants request or profile admission.
  internal init(configuration: URLSessionConfiguration, deadlineCapMilliseconds: Int,
    observe: @escaping @Sendable (NativeHTTPLifecycleEvent) -> Void) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.deadlineCapMilliseconds = max(1, deadlineCapMilliseconds)
    self.observe = observe
  }

  public func execute(
    key: String, configuration model: NativeOpenAIConfiguration,
    request: AuthorizedProviderRequest, authority: ProviderRequest
  ) async throws -> ValidatedProviderResult {
    guard !Task.isCancelled else { throw APIKeyConnectionError.cancelled }
    do { _ = try authority.encodeRequest(request) } catch {
      throw APIKeyConnectionError.invalidConfiguration
    }
    guard !key.isEmpty, key.utf8.count <= 4096,
      key.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e })
    else { throw APIKeyConnectionError.invalidKey }
    let operation = request.wire.operation
    let policy = authority.contract["operations"][operation.rawValue]
    let messages = try authority.renderMessages(request.wire)
    let approvedMilliseconds = authority.limit(operation == .connectionTest
      ? "probeDeadlineMs" : "generationDeadlineMs")
    let milliseconds = min(approvedMilliseconds, deadlineCapMilliseconds ?? approvedMilliseconds)
    var wire = URLRequest(url: NativeOpenAIConfiguration.endpoint)
    wire.httpMethod = "POST"
    wire.timeoutInterval = Double(approvedMilliseconds) / 1000
    wire.httpShouldHandleCookies = false
    wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
    wire.setValue(request.wire.requestID, forHTTPHeaderField: "X-Client-Request-Id")
    wire.httpBody = try ProviderRequest.canonicalBytes(.object([
      "model": .string(model.model),
      "messages": .array(messages.map {
        .object(["role": .string($0.role), "content": .string($0.content)])
      }),
      "max_completion_tokens": policy["outputTokens"],
      "stream": .bool(false), "n": .int(1), "store": .bool(false),
    ]))
    let config = configuration.copy() as! URLSessionConfiguration
    guard config.identifier == nil else { throw APIKeyConnectionError.invalidConfiguration }
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpCookieAcceptPolicy = .never
    config.httpShouldSetCookies = false
    config.httpAdditionalHeaders = nil
    config.urlCredentialStorage = nil
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = Double(approvedMilliseconds) / 1000
    config.timeoutIntervalForResource = Double(approvedMilliseconds) / 1000
    let bodyCap = operation == .connectionTest
      ? min(16_384, authority.limit("bodyBytes")) : authority.limit("bodyBytes")
    let owner = NativeHTTPRequestOwner(request: wire, configuration: config,
      milliseconds: milliseconds, bodyCap: bodyCap, observe: observe)
    let body = try await withTaskCancellationHandler {
      try await owner.run()
    } onCancel: {
      owner.cancel()
    }
    // run() returns only after task completion, session invalidation and serial
    // delegate-consumer drainage, on success AND every failure path.
    guard !Task.isCancelled else { throw APIKeyConnectionError.cancelled }
    do {
      try rejectDuplicateJSONKeys(body, maxDepth: authority.limit("depth"))
      guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
        object["object"] as? String == "chat.completion",
        let responseID = object["id"] as? String, !responseID.isEmpty,
        object["model"] as? String == model.model,
        let usage = object["usage"] as? [String: Any],
        let reportedTokens = usage["completion_tokens"],
        let tokens = try RequestValue(foundation: reportedTokens).integer,
        tokens > 0, tokens <= policy["outputTokens"].integer!,
        let choices = object["choices"] as? [[String: Any]], choices.count == 1,
        let choice = choices.first, let index = choice["index"],
        try RequestValue(foundation: index) == .int(0),
        choice["finish_reason"] as? String == "stop",
        let message = choice["message"] as? [String: Any],
        message["role"] as? String == "assistant", message["tool_calls"] == nil,
        message["function_call"] == nil,
        message["refusal"] == nil || message["refusal"] is NSNull,
        let text = message["content"] as? String
      else { throw APIKeyConnectionError.invalidResponse }
      let inputCharge = try authority.inputCharge(request.wire)
      if let prompt = usage["prompt_tokens"] {
        guard let count = try RequestValue(foundation: prompt).integer,
          count >= 0, count <= inputCharge
        else { throw APIKeyConnectionError.invalidResponse }
        if let total = usage["total_tokens"] {
          let sum = count.addingReportingOverflow(tokens)
          guard !sum.overflow, try RequestValue(foundation: total) == .int(sum.partialValue)
          else { throw APIKeyConnectionError.invalidResponse }
        }
      } else if let total = usage["total_tokens"] {
        guard let count = try RequestValue(foundation: total).integer,
          count >= tokens, count <= inputCharge + tokens
        else { throw APIKeyConnectionError.invalidResponse }
      }
      // Summary's outputBytes bounds its decoded text, not its entire JSON object.
      // The shared authority alone interprets and validates model result content.
      return try authority.wrapModelResult(Data(text.utf8), request: request)
    } catch { throw APIKeyConnectionError.invalidResponse }
  }
}

/// One request, one session, one serial delegate consumer. Cancellation only selects
/// a terminal reason and asks Foundation to stop; it never resumes the continuation.
private final class NativeHTTPRequestOwner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let queue: OperationQueue
  private let request: URLRequest
  private let configuration: URLSessionConfiguration
  private let deadline: DispatchTime
  private let bodyCap: Int
  private let observe: (@Sendable (NativeHTTPLifecycleEvent) -> Void)?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var timer: DispatchSourceTimer?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var failure: APIKeyConnectionError?
  private var body = Data()
  private var receivedResponse = false
  private var taskCompleted = false
  private var sessionInvalidated = false
  private var finished = false

  init(request: URLRequest, configuration: URLSessionConfiguration, milliseconds: Int,
    bodyCap: Int, observe: (@Sendable (NativeHTTPLifecycleEvent) -> Void)?) {
    self.request = request
    self.configuration = configuration
    self.bodyCap = bodyCap
    self.observe = observe
    deadline = .now() + .milliseconds(milliseconds)
    queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    super.init()
  }

  func run() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if failure == nil, DispatchTime.now() >= deadline { failure = .deadline }
      if let failure {
        lock.unlock()
        continuation.resume(throwing: failure)
        return
      }
      self.continuation = continuation
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      let task = session.dataTask(with: request)
      self.session = session
      self.task = task
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      self.timer = timer
      timer.setEventHandler { [weak self] in self?.fail(.deadline) }
      timer.schedule(deadline: deadline)
      timer.resume()
      task.resume()
      lock.unlock()
    }
  }

  func cancel() { fail(.cancelled) }

  private func fail(_ reason: APIKeyConnectionError) {
    lock.lock()
    guard !taskCompleted, !finished else { lock.unlock(); return }
    if failure == nil { failure = reason }
    let task = task
    let session = session
    lock.unlock()
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard DispatchTime.now() < deadline else {
      fail(.deadline)
      completionHandler(.cancel)
      return
    }
    guard let http = response as? HTTPURLResponse,
      http.url == NativeOpenAIConfiguration.endpoint else {
      fail(.invalidResponse)
      completionHandler(.cancel)
      return
    }
    let error: APIKeyConnectionError?
    switch http.statusCode {
    case 200: error = nil
    case 401, 403: error = .authentication
    case 400, 404, 422: error = .unsupportedProfile
    case 429: error = .rateLimited
    default: error = .providerUnavailable
    }
    if let error {
      fail(error)
      completionHandler(.cancel)
      return
    }
    guard http.mimeType?.lowercased() == "application/json",
      response.expectedContentLength <= Int64(bodyCap) else {
      fail(.invalidResponse)
      completionHandler(.cancel)
      return
    }
    lock.lock()
    receivedResponse = true
    let allowed = failure == nil
    lock.unlock()
    completionHandler(allowed ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard DispatchTime.now() < deadline else { fail(.deadline); return }
    lock.lock()
    guard failure == nil else { lock.unlock(); return }
    guard receivedResponse, data.count <= bodyCap - body.count else {
      lock.unlock()
      fail(.invalidResponse)
      return
    }
    body.append(data)
    lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    fail(.invalidResponse)
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
      ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
      ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    lock.lock()
    taskCompleted = true
    timer?.cancel()
    if failure == nil {
      if DispatchTime.now() >= deadline { failure = .deadline }
      else if let error = error as? URLError {
        switch error.code {
        case .timedOut: failure = .deadline
        case .cancelled: failure = .cancelled
        default: failure = .transport
        }
      } else if error != nil { failure = .transport }
      else if !receivedResponse { failure = .invalidResponse }
    }
    lock.unlock()
    observe?(.taskCompleted)
    session.finishTasksAndInvalidate()
    enqueueDrain()
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    lock.lock()
    sessionInvalidated = true
    if error != nil, failure == nil { failure = .transport }
    lock.unlock()
    observe?(.sessionInvalidated)
    enqueueDrain()
  }

  private func enqueueDrain() {
    // Runs after the current delegate operation returns. No async byte iterator or
    // detached consumer survives this single serial callback queue.
    queue.addOperation { [self] in
      lock.lock()
      guard taskCompleted, sessionInvalidated, !finished, let continuation else {
        lock.unlock()
        return
      }
      finished = true
      let result: Result<Data, any Error>
      if let failure { result = .failure(failure) }
      else { result = .success(body) }
      self.continuation = nil
      body = Data()
      timer = nil
      task = nil
      session = nil
      lock.unlock()
      observe?(.consumerDrained)
      continuation.resume(with: result)
    }
  }
}

/// Foundation accepts duplicate members. Reject them before decoding the HTTP envelope;
/// model result JSON is decoded separately by the existing shared request authority.
private func rejectDuplicateJSONKeys(_ data: Data, maxDepth: Int) throws {
  let bytes = Array(data)
  var objects: [Set<String>] = []
  var depth = 0
  var index = 0
  while index < bytes.count {
    switch bytes[index] {
    case 123:
      depth += 1
      objects.append([])
      guard depth <= maxDepth else { throw APIKeyConnectionError.invalidResponse }
    case 91:
      depth += 1
      guard depth <= maxDepth else { throw APIKeyConnectionError.invalidResponse }
    case 93:
      depth -= 1
      guard depth >= 0 else { throw APIKeyConnectionError.invalidResponse }
    case 125:
      depth -= 1
      guard !objects.isEmpty else { throw APIKeyConnectionError.invalidResponse }
      objects.removeLast()
    case 34:
      let start = index
      index += 1
      while index < bytes.count && bytes[index] != 34 {
        if bytes[index] == 92 { index += 1 }
        index += 1
      }
      guard index < bytes.count else { throw APIKeyConnectionError.invalidResponse }
      var next = index + 1
      while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
      if next < bytes.count && bytes[next] == 58 {
        guard !objects.isEmpty,
          let key = try JSONSerialization.jsonObject(
            with: Data(bytes[start...index]), options: [.fragmentsAllowed]) as? String,
          objects[objects.count - 1].insert(key).inserted
        else { throw APIKeyConnectionError.invalidResponse }
      }
    default: break
    }
    index += 1
  }
  guard objects.isEmpty, depth == 0 else { throw APIKeyConnectionError.invalidResponse }
}
