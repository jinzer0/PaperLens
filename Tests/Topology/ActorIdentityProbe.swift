import CoreFoundation
import Darwin
import Foundation
import Security

// Invocation-local, nonsandbox verifier. Its stdout is transient verifier RAM,
// never a report. Query only candidates supplied by the closed readiness fence.
@main
private enum ActorIdentityProbe {
  static let identity = "io.github.jinzer0.PaperLens"
  static let roles: [String: (String, String)] = [
    "Main": ("Contents/MacOS/PaperLens", identity),
    "ProviderAgent": (
      "Contents/XPCServices/ProviderAgent.xpc/Contents/MacOS/ProviderAgent",
      identity + ".ProviderAgent"
    ),
    "Python": (
      "Contents/XPCServices/ProviderAgent.xpc/Contents/Frameworks/PythonRuntime.framework/Versions/3.13/bin/python3.13",
      identity + ".ProviderAgent.Python"
    ),
    "PDFiumXPC": (
      "Contents/XPCServices/PDFiumXPC.xpc/Contents/MacOS/PDFiumXPC", identity + ".PDFiumXPC"
    ),
  ]

  static func emit(_ object: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { exit(2) }
    try? FileHandle.standardOutput.write(contentsOf: bytes)
  }

  static func blocked() -> Never {
    emit(["status": "blocked", "reason": "actor-identity-unproven"])
    exit(2)
  }

  static func integer(_ value: Any?) -> Int32? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
      number.compare(NSNumber(value: 0)) == .orderedDescending,
      number.compare(NSNumber(value: Int32.max)) != .orderedDescending
    else { return nil }
    return number.int32Value
  }

  static func birth(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB), info.pbi_status != 0,
      info.pbi_ruid == getuid(), info.pbi_uid == geteuid(), info.pbi_start_tvsec > 0,
      info.pbi_start_tvusec < 1_000_000, info.pbi_ppid > 0
    else { return nil }
    return info
  }

  static func sameBirth(_ a: proc_bsdinfo, _ b: proc_bsdinfo) -> Bool {
    a.pbi_pid == b.pbi_pid && a.pbi_ppid == b.pbi_ppid
      && a.pbi_start_tvsec == b.pbi_start_tvsec && a.pbi_start_tvusec == b.pbi_start_tvusec
      && a.pbi_uid == b.pbi_uid && a.pbi_ruid == b.pbi_ruid
  }

  static func cdHash(_ code: SecStaticCode) -> Data? {
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let fields = information as? [String: Any],
      let hash = fields[kSecCodeInfoUnique as String] as? Data,
      !hash.isEmpty
    else { return nil }
    return hash
  }

  static func main() {
    let args = CommandLine.arguments
    guard args.count == 3, args[1] == "--bundle", getuid() == geteuid(), getuid() >= 500 else {
      blocked()
    }
    let bundle = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let expected = source.appendingPathComponent(
      ".build/topology/arm64/PaperLens.app", isDirectory: true)
    guard bundle == expected, bundle.resolvingSymlinksInPath() == bundle else { blocked() }
    var bytes = Data()
    // A closed pipe is required; the Python caller owns a strict timeout.
    while let chunk = try? FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
      bytes.append(chunk)
      if bytes.count > 65_536 { blocked() }
    }
    guard let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(input.keys) == ["actors"], let actors = input["actors"] as? [[String: Any]],
      actors.count == 1 || actors.count == 4
    else { blocked() }
    var candidates: [String: Int32] = [:]
    for actor in actors {
      guard Set(actor.keys) == ["role", "pid"], let role = actor["role"] as? String,
        roles[role] != nil, candidates[role] == nil, let pid = integer(actor["pid"])
      else { blocked() }
      candidates[role] = pid
    }
    guard Set(candidates.keys) == Set(roles.keys) || Set(candidates.keys) == ["PDFiumXPC"],
      Set(candidates.values).count == candidates.count
    else { blocked() }
    var records: [[String: Any]] = []
    for role in candidates.keys.sorted() {
      guard let pid = candidates[role], let (relative, identifier) = roles[role],
        let pre = birth(pid)
      else { blocked() }
      let executable = bundle.appendingPathComponent(relative)
      var info = stat()
      guard executable.resolvingSymlinksInPath() == executable,
        lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
      else { blocked() }
      let expression =
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"397452Z366\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      var requirement: SecRequirement?
      var guest: SecCode?
      var expectedCode: SecStaticCode?
      guard
        SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
        let requirement,
        SecStaticCodeCreateWithPath(executable as CFURL, [], &expectedCode) == errSecSuccess,
        let expectedCode,
        SecStaticCodeCheckValidity(expectedCode, [], requirement) == errSecSuccess,
        SecCodeCopyGuestWithAttributes(
          nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &guest)
          == errSecSuccess,
        let guest, SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,
        // The public API explicitly accepts a dynamic SecCodeRef despite its
        // C parameter being spelled SecStaticCodeRef. Keep the guest object:
        // copying its static code would query the file, not the live process.
        let expectedHash = cdHash(expectedCode),
        let actualHash = cdHash(unsafeBitCast(guest, to: SecStaticCode.self)),
        expectedHash == actualHash,
        let post = birth(pid), sameBirth(pre, post)
      else { blocked() }
      if role == "Python" && post.pbi_ppid != UInt32(candidates["ProviderAgent"] ?? 0) { blocked() }
      // Main can be launched by any legitimate launcher. Do not enumerate or
      // query that launcher; only Python's owned bridge relationship is fixed.
      records.append([
        "role": role, "pid": Int(pid), "parentPID": Int(post.pbi_ppid),
        "birthSec": post.pbi_start_tvsec, "birthUsec": post.pbi_start_tvusec,
        "codeIdentityRef": identifier, "verified": true,
      ])
    }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0
    else { blocked() }
    emit([
      "status": "verified", "actors": records,
      "timebase": ["numerator": timebase.numer, "denominator": timebase.denom],
    ])
  }
}
