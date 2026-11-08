import Foundation

/// CI supplies its installed, pinned interpreter only to synthetic fixtures.
/// Production still resolves Python exclusively from the signed embedded bundle.
enum SyntheticPython {
  static var override: URL? {
    guard let path = ProcessInfo.processInfo.environment["PAPERLENS_FIXTURE_PYTHON"],
      path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
  }

  static var metadataInterpreter: URL {
    override ?? URL(fileURLWithPath: "/usr/bin/python3")
  }
}
