import CoreFoundation
import Foundation

public enum ProviderRPCError: Error, Equatable {
  case protocolViolation
  case invalidParams
  case unknownMethod
}

@objc public protocol ProviderFrameTransport {
  func sendFrame(_ frame: Data)
}

@objc public protocol ProviderFrameReceiver {
  func receiveFrame(_ frame: Data)
}

public enum ProviderRPC {
  public static let maxBodyBytes = 65536
  public static let maxFrameBytes = 65540
  private static let store = ContractStore()

  public static func configure(contractURL: URL) throws {
    try store.configure(url: contractURL)
  }

  public static func limit(_ name: String) throws -> Int {
    try store.load().limit(name)
  }

  public static func encode(_ object: [String: Any]) throws -> Data {
    let contract = try store.load()
    try contract.checkStructure(object)
    var body = Data()
    try appendJSON(object, to: &body)
    guard !body.isEmpty else { throw ProviderRPCError.protocolViolation }
    let count = UInt32(body.count)
    var frame = Data([
      UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
      UInt8((count >> 8) & 255), UInt8(count & 255),
    ])
    frame.append(body)
    return frame
  }

  public static func decode(_ frame: Data) throws -> [String: Any] {
    guard frame.count >= 5, frame.count <= maxFrameBytes else {
      throw ProviderRPCError.protocolViolation
    }
    let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= maxBodyBytes, frame.count == length + 4 else {
      throw ProviderRPCError.protocolViolation
    }
    var parser = JSONParser(bytes: Array(frame.dropFirst(4)), contract: try store.load())
    return try parser.parse()
  }

  /// Exact unsigned control metadata; booleans, real numbers and overflow are rejected.
  public static func exactUInt64(_ value: Any?) -> UInt64? {
    if let integer = value as? JSONInteger { return UInt64(integer.literal) }
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: number.objCType))
    else { return nil }
    return UInt64(number.stringValue)
  }

  public static func validateRequest(_ object: [String: Any]) throws {
    let contract = try store.load()
    try contract.checkStructure(object)
    guard try contract.matches(object, schema: contract.envelope("request")),
      let name = object["method"] as? String
    else {
      throw ProviderRPCError.protocolViolation
    }
    guard let method = contract.methods[name] as? [String: Any] else {
      throw ProviderRPCError.unknownMethod
    }
    guard let params = method["params"] as? [String: Any],
      let value = object["params"], try contract.matches(value, schema: params)
    else {
      throw ProviderRPCError.invalidParams
    }
  }

  public static func validateTerminal(_ object: [String: Any], method: String) throws {
    let contract = try store.load()
    try contract.checkStructure(object)
    guard let kind = object["kind"] as? String, kind == "result" || kind == "error",
      try contract.matches(object, schema: contract.envelope(kind))
    else {
      throw ProviderRPCError.protocolViolation
    }
    if kind == "result" {
      guard let definition = contract.methods[method] as? [String: Any] else {
        throw ProviderRPCError.unknownMethod
      }
      guard let schema = definition["result"] as? [String: Any],
        let value = object["result"], try contract.matches(value, schema: schema)
      else {
        throw ProviderRPCError.protocolViolation
      }
    }
  }

  private static func append(_ bytes: Data, to body: inout Data) throws {
    guard bytes.count <= maxBodyBytes - body.count else {
      throw ProviderRPCError.protocolViolation
    }
    body.append(bytes)
  }

  private static func appendJSON(_ value: Any, to body: inout Data) throws {
    if let integer = value as? JSONInteger {
      try append(Data(integer.literal.utf8), to: &body)
    } else if let object = value as? [String: Any] {
      try append(Data([123]), to: &body)
      for (index, key) in object.keys.sorted().enumerated() {
        if index > 0 { try append(Data([44]), to: &body) }
        try appendJSON(key, to: &body)
        try append(Data([58]), to: &body)
        guard let item = object[key] else { throw ProviderRPCError.protocolViolation }
        try appendJSON(item, to: &body)
      }
      try append(Data([125]), to: &body)
    } else if let array = value as? [Any] {
      try append(Data([91]), to: &body)
      for (index, item) in array.enumerated() {
        if index > 0 { try append(Data([44]), to: &body) }
        try appendJSON(item, to: &body)
      }
      try append(Data([93]), to: &body)
    } else {
      do {
        var bytes = try JSONSerialization.data(
          withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        if let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          type(of: value) == Double.self || type(of: value) == Float.self
            || ["f", "d"].contains(String(cString: number.objCType)),
          !bytes.contains(46), !bytes.contains(69), !bytes.contains(101)
        {
          bytes.append(contentsOf: [46, 48])
        }
        try append(bytes, to: &body)
      } catch {
        throw ProviderRPCError.protocolViolation
      }
    }
  }
}

private final class ContractBundleToken: NSObject {}

private final class ContractStore: @unchecked Sendable {
  private let lock = NSLock()
  private var contract: Contract?

  func configure(url: URL) throws {
    let loaded = try Contract(url: url)
    lock.lock()
    defer { lock.unlock() }
    contract = loaded
  }

  func load() throws -> Contract {
    lock.lock()
    defer { lock.unlock() }
    if let contract { return contract }
    var bundles: [Bundle] = []
    #if SWIFT_PACKAGE
      bundles.append(Bundle.module)
    #endif
    bundles.append(contentsOf: [Bundle.main, Bundle(for: ContractBundleToken.self)])
    for bundle in bundles {
      for directory in ["ProviderRPC", nil] as [String?] {
        if let url = bundle.url(
          forResource: "contract", withExtension: "json", subdirectory: directory)
        {
          let loaded = try Contract(url: url)
          contract = loaded
          return loaded
        }
      }
    }
    throw ProviderRPCError.protocolViolation
  }
}

private struct Contract {
  let limits: [String: Int]
  let definitions: [String: Any]
  let envelopes: [String: Any]
  let methods: [String: Any]

  init(url: URL) throws {
    do {
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
      guard let root = value as? [String: Any],
        let limits = root["limits"] as? [String: Int],
        let definitions = root["definitions"] as? [String: Any],
        let envelopes = root["envelopes"] as? [String: Any],
        let methods = root["methods"] as? [String: Any],
        limits["maxBodyBytes"] == ProviderRPC.maxBodyBytes,
        limits["maxFrameBytes"] == ProviderRPC.maxFrameBytes,
        limits["maxAuthURLBytes"] == 4096,
        ["maxDepth", "maxObjectKeys", "maxArrayItems", "maxStringBytes"].allSatisfy({
          (limits[$0] ?? 0) > 0
        })
      else {
        throw ProviderRPCError.protocolViolation
      }
      self.limits = limits
      self.definitions = definitions
      self.envelopes = envelopes
      self.methods = methods
    } catch {
      throw ProviderRPCError.protocolViolation
    }
  }

  func limit(_ name: String) throws -> Int {
    guard let value = limits[name] else { throw ProviderRPCError.protocolViolation }
    return value
  }

  func envelope(_ name: String) throws -> [String: Any] {
    guard let value = envelopes[name] as? [String: Any] else {
      throw ProviderRPCError.protocolViolation
    }
    return value
  }

  func checkString(_ string: String, maximum: Int? = nil) throws {
    guard try string.utf8.count <= (maximum ?? limit("maxStringBytes")) else {
      throw ProviderRPCError.protocolViolation
    }
  }

  func checkStructure(_ value: Any) throws {
    var browser = false
    if let object = value as? [String: Any],
      try matches(object, schema: envelope("result")),
      let definition = methods["product.loginStart"] as? [String: Any],
      let schema = definition["result"] as? [String: Any],
      let result = object["result"] as? [String: Any],
      try matches(result, schema: schema),
      let instructions = result["instructions"] as? [String: Any]
    {
      browser = instructions["mode"] as? String == "browser"
    }
    try checkStructure(value, depth: 0, path: [], browser: browser)
  }

  private func checkStructure(_ value: Any, depth: Int, path: [String], browser: Bool) throws {
    if value is JSONInteger {
      return
    } else if let object = value as? [String: Any] {
      guard try depth < limit("maxDepth"), try object.count <= limit("maxObjectKeys") else {
        throw ProviderRPCError.protocolViolation
      }
      for (key, item) in object {
        try checkString(key)
        try checkStructure(item, depth: depth + 1, path: path + [key], browser: browser)
      }
    } else if let array = value as? [Any] {
      guard try depth < limit("maxDepth"), try array.count <= limit("maxArrayItems") else {
        throw ProviderRPCError.protocolViolation
      }
      for item in array {
        try checkStructure(item, depth: depth + 1, path: path + [""], browser: browser)
      }
    } else if let string = value as? String {
      var maximum: Int?
      if browser && path == ["result", "instructions", "authUrl"] {
        maximum = try limit("maxAuthURLBytes")
      }
      try checkString(string, maximum: maximum)
    } else if let number = value as? NSNumber {
      guard number.doubleValue.isFinite else { throw ProviderRPCError.protocolViolation }
    } else if !(value is NSNull) {
      throw ProviderRPCError.protocolViolation
    }
  }

  func matches(_ value: Any, schema: [String: Any]) throws -> Bool {
    if schema["nullable"] as? Bool == true, value is NSNull { return true }
    if let branches = schema["oneOf"] as? [[String: Any]] {
      var count = 0
      for branch in branches { if try matches(value, schema: branch) { count += 1 } }
      return count == 1
    }
    if let ref = schema["ref"] as? String {
      guard let target = definitions[ref] as? [String: Any] else {
        throw ProviderRPCError.protocolViolation
      }
      return try matches(value, schema: target)
    }
    switch schema["type"] as? String {
    case "object":
      guard let object = value as? [String: Any] else { return false }
      if let fields = schema["fields"] as? [String: Any] {
        guard Set(object.keys) == Set(fields.keys) else { return false }
        for (key, rule) in fields {
          guard let child = object[key], let childSchema = rule as? [String: Any],
            try matches(child, schema: childSchema)
          else { return false }
        }
      }
      if schema["cleanProof"] as? Bool == true, object["state"] as? String == "clean" {
        for key in ["stopped", "closed", "absent"] {
          guard let proof = object[key] as? NSNumber,
            CFGetTypeID(proof) == CFBooleanGetTypeID(), proof.boolValue
          else { return false }
        }
      }
      if let observation = schema["syscallObservation"] as? [String: String] {
        guard let observedKey = observation["observed"],
          let observed = object[observedKey] as? Bool,
          let resultKey = observation["result"], let result = object[resultKey] as? NSNumber,
          let errnoKey = observation["errno"], let error = object[errnoKey] as? NSNumber,
          let beganKey = observation["began"], let began = object[beganKey] as? NSNumber,
          let endedKey = observation["ended"], let ended = object[endedKey] as? NSNumber
        else { return false }
        // Field schemas above guarantee exact bounded integers before these comparisons.
        if !observed {
          if [result, error, began, ended].contains(where: { $0.int64Value != 0 }) {
            return false
          }
        } else if began.compare(ended) != .orderedAscending
          || (result.int64Value >= 0 && error.int64Value != 0)
        {
          return false
        }
      }
    case "array":
      guard let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] else {
        return false
      }
      for item in array {
        if try !matches(item, schema: itemSchema) { return false }
      }
    case "integer":
      let minimum =
        schema["minimum"] as? Int
        ?? (schema["minimumLimit"] as? String).flatMap { limits[$0] }
      let maximum =
        schema["maximum"] as? Int
        ?? (schema["maximumLimit"] as? String).flatMap { limits[$0] }
      if let integer = value as? JSONInteger {
        if let minimum, integer.compare(to: minimum) == .orderedAscending { return false }
        if let maximum, integer.compare(to: maximum) == .orderedDescending { return false }
      } else {
        guard type(of: value) != Double.self, type(of: value) != Float.self,
          let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType))
        else { return false }
        if let minimum, number.compare(NSNumber(value: minimum)) == .orderedAscending {
          return false
        }
        if let maximum, number.compare(NSNumber(value: maximum)) == .orderedDescending {
          return false
        }
      }
    case "boolean":
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return false
      }
    case "string":
      guard let string = value as? String else { return false }
      let ordinaryMaximum = try limit("maxStringBytes")
      let maximum =
        schema["maxBytes"] as? Int
        ?? (schema["maxBytesLimit"] as? String).flatMap { limits[$0] }
        ?? ordinaryMaximum
      guard string.utf8.count >= (schema["minBytes"] as? Int ?? 0),
        string.utf8.count <= maximum
      else { return false }
      if schema["httpsUrl"] as? Bool == true, !httpsURL(string) { return false }
    case "null":
      guard value is NSNull else { return false }
    case "uuid":
      guard let string = value as? String, let uuid = UUID(uuidString: string),
        uuid.uuidString.lowercased() == string
      else { return false }
      let bytes = Array(string.utf8)
      guard bytes.count == 36, bytes[14] == 52, [56, 57, 97, 98].contains(bytes[19]) else {
        return false
      }
    default:
      throw ProviderRPCError.protocolViolation
    }
    if let constant = schema["const"], !equalJSON(value, constant) { return false }
    if let values = schema["enum"] as? [Any], !values.contains(where: { equalJSON(value, $0) }) {
      return false
    }
    return true
  }

  private func httpsURL(_ string: String) -> Bool {
    guard
      !string.unicodeScalars.contains(where: {
        $0.value < 32 || (127...159).contains($0.value)
          || CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 92
      }), let components = URLComponents(string: string),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      let schemeEnd = string.range(of: "://")
    else { return false }
    let authority = string[schemeEnd.upperBound...].utf8.prefix {
      $0 != 47 && $0 != 63 && $0 != 35
    }
    guard !authority.contains(64) else { return false }
    var suffix = authority.dropFirst(authority.count)
    if authority.first == 91 {
      guard let end = authority.firstIndex(of: 93) else { return false }
      suffix = authority[authority.index(after: end)...]
    } else if let colon = authority.firstIndex(of: 58) {
      suffix = authority[colon...]
    }
    if !suffix.isEmpty {
      guard suffix.first == 58, suffix.count > 1,
        suffix.dropFirst().allSatisfy({ (48...57).contains($0) }),
        let port = Int(String(decoding: suffix.dropFirst(), as: UTF8.self)),
        (0...65535).contains(port)
      else { return false }
    }
    return true
  }

  private func equalJSON(_ lhs: Any, _ rhs: Any) -> Bool {
    if let integer = lhs as? JSONInteger, let constant = rhs as? Int {
      return integer.compare(to: constant) == .orderedSame
    }
    guard let left = lhs as? NSObject, let right = rhs as? NSObject else { return false }
    return left.isEqual(right)
  }
}

// Preserve integers beyond NSNumber's exact range without narrowing or inventing a wire limit.
// Ordinary integers still decode as NSNumber; large version values remain valid integers.
private struct JSONInteger {
  let literal: String

  func compare(to value: Int) -> ComparisonResult {
    let other = String(value)
    let negative = literal.first == "-"
    let otherNegative = other.first == "-"
    if negative != otherNegative { return negative ? .orderedAscending : .orderedDescending }
    let magnitude = negative ? literal.dropFirst() : literal[...]
    let otherMagnitude = otherNegative ? other.dropFirst() : other[...]
    if magnitude == otherMagnitude { return .orderedSame }
    let smaller =
      magnitude.count == otherMagnitude.count
      ? magnitude.lexicographicallyPrecedes(otherMagnitude)
      : magnitude.count < otherMagnitude.count
    return smaller != negative ? .orderedAscending : .orderedDescending
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  let contract: Contract
  private var offset = 0

  init(bytes: [UInt8], contract: Contract) {
    self.bytes = bytes
    self.contract = contract
  }

  mutating func parse() throws -> [String: Any] {
    // Validate before decoding any token: incoming UTF-8 must never be repaired.
    guard String(bytes: bytes, encoding: .utf8) != nil else {
      throw ProviderRPCError.protocolViolation
    }
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard offset == bytes.count, let object = value as? [String: Any] else {
      throw ProviderRPCError.protocolViolation
    }
    try contract.checkStructure(object)
    return object
  }

  private mutating func skipWhitespace() {
    while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard offset < bytes.count, bytes[offset] == byte else { return false }
    offset += 1
    return true
  }

  private mutating func parseValue(depth: Int) throws -> Any {
    skipWhitespace()
    guard offset < bytes.count else { throw ProviderRPCError.protocolViolation }
    switch bytes[offset] {
    case 123:
      guard try depth < contract.limit("maxDepth") else { throw ProviderRPCError.protocolViolation }
      offset += 1
      skipWhitespace()
      var object: [String: Any] = [:]
      if consume(125) { return object }
      while true {
        skipWhitespace()
        let key = try parseString(isKey: true)
        guard object[key] == nil, try object.count < contract.limit("maxObjectKeys") else {
          throw ProviderRPCError.protocolViolation
        }
        skipWhitespace()
        guard consume(58) else { throw ProviderRPCError.protocolViolation }
        object[key] = try parseValue(depth: depth + 1)
        skipWhitespace()
        if consume(125) { return object }
        guard consume(44) else { throw ProviderRPCError.protocolViolation }
      }
    case 91:
      guard try depth < contract.limit("maxDepth") else { throw ProviderRPCError.protocolViolation }
      offset += 1
      skipWhitespace()
      var array: [Any] = []
      if consume(93) { return array }
      while true {
        guard try array.count < contract.limit("maxArrayItems") else {
          throw ProviderRPCError.protocolViolation
        }
        array.append(try parseValue(depth: depth + 1))
        skipWhitespace()
        if consume(93) { return array }
        guard consume(44) else { throw ProviderRPCError.protocolViolation }
      }
    case 34:
      return try parseString()
    case 116:
      try literal(Array("true".utf8))
      return true
    case 102:
      try literal(Array("false".utf8))
      return false
    case 110:
      try literal(Array("null".utf8))
      return NSNull()
    case 45, 48...57:
      return try parseNumber()
    default:
      throw ProviderRPCError.protocolViolation
    }
  }

  private mutating func literal(_ literal: [UInt8]) throws {
    guard offset + literal.count <= bytes.count,
      Array(bytes[offset..<(offset + literal.count)]) == literal
    else {
      throw ProviderRPCError.protocolViolation
    }
    offset += literal.count
  }

  private mutating func parseString(isKey: Bool = false) throws -> String {
    let start = offset
    guard consume(34) else { throw ProviderRPCError.protocolViolation }
    while offset < bytes.count {
      let byte = bytes[offset]
      offset += 1
      if byte == 34 {
        do {
          let value = try JSONSerialization.jsonObject(
            with: Data(bytes[start..<offset]), options: .fragmentsAllowed)
          guard let string = value as? String else { throw ProviderRPCError.protocolViolation }
          // Bounded lexical retention only; parse() validates the exact root/path before export.
          try contract.checkString(
            string, maximum: contract.limit(isKey ? "maxStringBytes" : "maxAuthURLBytes"))
          return string
        } catch { throw ProviderRPCError.protocolViolation }
      }
      if byte == 92 {
        guard offset < bytes.count else { throw ProviderRPCError.protocolViolation }
        offset += 1
      } else if byte < 32 {
        throw ProviderRPCError.protocolViolation
      }
    }
    throw ProviderRPCError.protocolViolation
  }

  private mutating func parseNumber() throws -> Any {
    let start = offset
    while offset < bytes.count,
      [45, 43, 46, 69, 101].contains(bytes[offset]) || (48...57).contains(bytes[offset])
    {
      offset += 1
    }
    let literal = String(decoding: bytes[start..<offset], as: UTF8.self)
    guard
      literal.range(
        of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression)
        != nil
    else {
      throw ProviderRPCError.protocolViolation
    }
    if !bytes[start..<offset].contains(where: { [46, 69, 101].contains($0) }) {
      if let integer = Int64(literal) { return NSNumber(value: integer) }
      if let integer = UInt64(literal) { return NSNumber(value: integer) }
      return JSONInteger(literal: literal)
    }
    guard let number = Double(literal), number.isFinite else {
      throw ProviderRPCError.protocolViolation
    }
    return number
  }
}

public final class ProviderFrameDecoder {
  private var buffer = Data()
  private var bodyLength: Int?
  private var failed = false
  private var closed = false

  public init() {}

  public func finish() throws {
    guard !failed, buffer.isEmpty, bodyLength == nil else {
      failed = true
      buffer = Data()
      bodyLength = nil
      throw ProviderRPCError.protocolViolation
    }
    closed = true
  }

  public func feed(_ bytes: Data) throws -> [Data] {
    guard !failed, !closed else { throw ProviderRPCError.protocolViolation }
    var frames: [Data] = []
    var offset = bytes.startIndex
    do {
      while offset < bytes.endIndex {
        let target = bodyLength.map { $0 + 4 } ?? 4
        let count = min(target - buffer.count, bytes.endIndex - offset)
        buffer.append(contentsOf: bytes[offset..<(offset + count)])
        offset += count
        if bodyLength == nil, buffer.count == 4 {
          let length = buffer.reduce(0) { ($0 << 8) | Int($1) }
          guard length > 0, length <= ProviderRPC.maxBodyBytes else {
            throw ProviderRPCError.protocolViolation
          }
          bodyLength = length
        }
        if let length = bodyLength, buffer.count == length + 4 {
          _ = try ProviderRPC.decode(buffer)
          frames.append(buffer)
          buffer = Data()
          bodyLength = nil
        }
      }
      return frames
    } catch {
      failed = true
      buffer = Data()
      bodyLength = nil
      throw ProviderRPCError.protocolViolation
    }
  }
}
