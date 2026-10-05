import Darwin
import Foundation

// Standalone signed test target only. Never compile this entry point into a
// product target or give the product its fixture-only app-group entitlement.
@main
private enum FixtureGroupOwner {
  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--run-id",
      TopologyFixtures.validRunID(arguments[2])
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "invalidInvocation"])
      exit(2)
    }
    guard
      TopologyFixtures.profileMatches(TopologyIdentity.groupOwner),
      TopologyFixtures.groupMapMatches(),
      let groupRoot = TopologyFixtures.groupRoot
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "profileUnavailable"])
      exit(2)
    }
    guard
      let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: TopologyIdentity.group)
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "groupUnavailable"])
      exit(2)
    }
    guard
      group.isFileURL, group.standardizedFileURL.path == groupRoot,
      group.resolvingSymlinksInPath() == group.standardizedFileURL
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "groupPathMismatch"])
      exit(2)
    }
    guard let groupDirectory = TopologyFixtures.directory(group, create: false)
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "groupDirectoryUnavailable"])
      exit(2)
    }
    close(groupDirectory)
    let runID = arguments[2]
    guard
      let owner = TopologyOwnedFixtures(
        root: group.appendingPathComponent("PaperLensTopology"), runID: runID),
      owner.create("G"), owner.check()
    else {
      emit(["status": "blocked", "fixtureID": "G", "reason": "fixtureUnavailable"])
      exit(2)
    }
    // The harness keeps this owner alive throughout probes, then signals it.
    // No separate cleanup invocation can adopt a pre-existing user's file.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let finish: @Sendable () -> Void = {
      let intact = owner.check()
      let absent = owner.cleanup()
      emit([
        "status": intact && absent ? "complete" : "failed", "runID": runID,
        "fixtureID": "G", "ownerPost": intact ? "pass" : "failed", "absent": absent,
      ])
      exit(intact && absent ? 0 : 1)
    }
    termination.setEventHandler(handler: finish)
    interrupt.setEventHandler(handler: finish)
    termination.resume()
    interrupt.resume()
    emit([
      "status": "ready", "runID": runID, "fixtureID": "G", "ownerPre": "pass",
      "expectedRootMatched": true, "posixACLControl": "unverified",
    ])
    withExtendedLifetime((owner, termination, interrupt)) { dispatchMain() }
  }

  private static func emit(_ value: [String: Any]) {
    var data = TopologyFixtures.json(value)
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
  }
}
