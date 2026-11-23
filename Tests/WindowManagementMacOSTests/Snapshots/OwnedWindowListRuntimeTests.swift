import AppKit
import CoreGraphics
import WindowManagement
import WindowManagementMacOS
import XCTest

@MainActor
final class OwnedWindowListRuntimeTests: XCTestCase {
  func testOwnedWindowsSupportQueryOrderHitAndFreshRemoval() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WINDOW_MANAGEMENT_RUN_OWNED_CG_TESTS"] == "1" else {
      throw XCTSkip("Owned Core Graphics acceptance requires explicit opt-in in an isolated VM.")
    }
    guard environment["NAVI_CI_OWNED_VM"] == "1" else {
      throw OwnedCGFailure.environment("NAVI_CI_OWNED_VM=1 is required for owned window acceptance")
    }
    guard let sourceCommit = environment["NAVI_CI_SOURCE_COMMIT"],
      sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
      let sourceFingerprint = environment["NAVI_CI_SOURCE_FINGERPRINT"],
      sourceFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else {
      throw OwnedCGFailure.environment("The captured source commit and fingerprint are required")
    }
    guard let screen = NSScreen.screens.first, screen.visibleFrame.width >= 320,
      screen.visibleFrame.height >= 240
    else {
      throw OwnedCGFailure.environment("A usable WindowServer display is unavailable")
    }

    let application = NSApplication.shared
    let previousPolicy = application.activationPolicy()
    if previousPolicy == .prohibited, !application.setActivationPolicy(.accessory) {
      throw OwnedCGFailure.environment("The test process cannot present its owned windows")
    }
    let bounds = screen.visibleFrame
    let width = min(360, bounds.width * 0.6)
    let height = min(240, bounds.height * 0.6)
    let frame = CGRect(
      x: bounds.midX - width / 2, y: bounds.midY - height / 2,
      width: width, height: height)
    let back = makeWindow(frame: frame, title: "WindowManagement owned CG back")
    let front = makeWindow(frame: frame, title: "WindowManagement owned CG front")
    let windows = [back, front]
    var windowsToClose = windows
    defer {
      for window in windowsToClose {
        window.orderOut(nil)
        window.close()
      }
      if application.activationPolicy() != previousPolicy {
        _ = application.setActivationPolicy(previousPolicy)
      }
    }

    var evidence: [String: Any] = [
      "kind": "owned Core Graphics query and hit acceptance",
      "processIdentifier": ProcessInfo.processInfo.processIdentifier,
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "sourceCommit": sourceCommit,
      "sourceFingerprint": sourceFingerprint,
      "initialActivationPolicy": previousPolicy.rawValue,
      "observations": [],
      "result": "started",
    ]
    do {
      back.orderFrontRegardless()
      front.orderFrontRegardless()
      guard let backID = CGWindowID(exactly: back.windowNumber), backID != 0,
        let frontID = CGWindowID(exactly: front.windowNumber), frontID != 0, backID != frontID
      else {
        throw OwnedCGFailure.environment(
          "The owned windows did not receive distinct CG identifiers")
      }
      let identifiers: Set<CGWindowID> = [backID, frontID]
      let process = ProcessInfo.processInfo.processIdentifier
      evidence["ownedWindowIdentifiers"] = identifiers.sorted()
      let initial = try waitFor(
        failure: .environment("The WindowServer did not publish both owned windows on screen")
      ) { () -> [RawWindow]? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          Set(rows.map(\.identifier)) == identifiers,
          rows.first?.identifier == frontID
        else { return nil }
        return rows
      }
      let filter = WindowSnapshotFilter(
        includedOwnerProcessIdentifiers: [Int64(process)],
        includedWindowIdentifiers: Set(identifiers.map { UInt64($0) }))
      let query = WindowSnapshotQuery(filter: filter)
      let topmost = WindowSnapshotQuery(filter: filter, limit: .topmostMatchingWindow)
      let hitTester = WindowHitTester(filter: filter)

      let listed = try query.snapshots()
      try require(
        listed.map(\.windowIdentifier) == initial.map(\.identifier),
        "The constrained query did not preserve the owned CG source order")
      try require(
        listed.allSatisfy { $0.ownerProcessIdentifier == process },
        "The constrained query returned a different owning process")
      for row in initial {
        guard let snapshot = try query.snapshot(for: row.identifier) else {
          throw OwnedCGFailure.semantic("The known-ID query did not return the owned window")
        }
        try require(
          snapshot.windowIdentifier == row.identifier && snapshot.ownerProcessIdentifier == process,
          "The known-ID query returned a different native identity")
        try require(snapshot.frame == row.frame.standardized, "The known-ID CG frame changed")
      }
      let overlap = initial[0].frame.intersection(initial[1].frame)
      guard !overlap.isNull && !overlap.isEmpty else {
        throw OwnedCGFailure.environment("The owned CG frames do not overlap")
      }
      let point = CGPoint(x: overlap.midX, y: overlap.midY)
      evidence["pointFromQueriedCGFrames"] = [Double(point.x), Double(point.y)]
      try assertTopmost(frontID, query: topmost, hitTester: hitTester, point: point)
      appendObservation("initial", rows: listed, to: &evidence)

      front.alphaValue = 0
      let transparentRows = try waitFor(
        failure: .environment("The WindowServer did not update the owned front window's alpha")
      ) { () -> [RawWindow]? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          rows.contains(where: { $0.identifier == backID })
        else { return nil }
        if let frontRow = rows.first(where: { $0.identifier == frontID }), frontRow.alpha != 0 {
          return nil
        }
        return rows
      }
      let transparentFront = transparentRows.first { $0.identifier == frontID }
      let transparentFrontWasFirst = transparentRows.first?.identifier == frontID
      let transparentHit = hitTester.hitTest(at: point).snapshot?.windowIdentifier
      evidence["fullyTransparentOverlap"] = [
        "frontReturnedInOnScreenList": transparentFront != nil,
        "frontFirstInOnScreenList": transparentFrontWasFirst,
        "frontReportedAlpha": transparentFront?.alpha.map { $0 as Any } ?? NSNull(),
        "rawWindowIdentifiers": transparentRows.map(\.identifier),
        "selectedWindowIdentifier": transparentHit.map { $0 as Any } ?? NSNull(),
        "visibleWindowIdentifier": backID,
      ]
      try require(transparentHit == backID, "A fully transparent window won the owned CG hit")
      if transparentFront != nil {
        try require(
          try query.snapshots().contains { $0.windowIdentifier == frontID },
          "Alpha filtering leaked into snapshot enumeration")
      }

      front.alphaValue = 1
      front.orderFrontRegardless()
      _ = try waitFor(failure: .environment("The owned front window did not become opaque again")) {
        () -> Bool? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          rows.first?.identifier == frontID, rows.first?.alpha == 1
        else { return nil }
        return true
      }
      try assertTopmost(frontID, query: topmost, hitTester: hitTester, point: point)

      back.orderFrontRegardless()
      let reordered = try waitFor(
        failure: .environment("The WindowServer did not reorder both owned windows")
      ) { () -> [RawWindow]? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          Set(rows.map(\.identifier)) == identifiers, rows.first?.identifier == backID
        else { return nil }
        return rows
      }
      try assertTopmost(backID, query: topmost, hitTester: hitTester, point: point)
      let reorderedSnapshots = try query.snapshots()
      try require(
        reorderedSnapshots.map(\.windowIdentifier) == reordered.map(\.identifier),
        "The constrained query did not retain both reordered owned windows")
      appendObservation("reordered", rows: reorderedSnapshots, to: &evidence)

      back.orderOut(nil)
      back.close()
      windowsToClose.removeAll { $0 === back }
      _ = try waitFor(failure: .environment("The closed owned window remained on screen")) {
        () -> [RawWindow]? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          rows.map(\.identifier) == [frontID]
        else { return nil }
        return rows
      }
      let remaining = try query.snapshots()
      try require(
        remaining.map(\.windowIdentifier) == [frontID],
        "A fresh on-screen query retained the closed window")
      try assertTopmost(frontID, query: topmost, hitTester: hitTester, point: point)
      appendObservation("after-close", rows: remaining, to: &evidence)
      for window in windowsToClose {
        window.orderOut(nil)
        window.close()
      }
      windowsToClose.removeAll()
      _ = try waitFor(failure: .environment("The owned windows remained on screen during cleanup"))
      { () -> Bool? in
        guard let rows = self.rawOwnedWindows(identifiers: identifiers, process: process),
          rows.isEmpty
        else { return nil }
        return true
      }
      try require(
        windows.allSatisfy { !$0.isVisible }, "An owned window remained visible after cleanup")
      if application.activationPolicy() != previousPolicy {
        guard application.setActivationPolicy(previousPolicy) else {
          throw OwnedCGFailure.environment("The test process activation policy was not restored")
        }
      }
      guard application.activationPolicy() == previousPolicy else {
        throw OwnedCGFailure.environment(
          "The test process activation policy restoration did not apply")
      }
      evidence["cleanup"] = [
        "ownedWindowsOnScreen": 0,
        "ownedWindowsVisible": 0,
        "activationPolicyRestored": application.activationPolicy() == previousPolicy,
      ]
      evidence["result"] = "passed"
      try writeEvidence(evidence, environment: environment)
    } catch {
      evidence["result"] = "failed"
      evidence["failure"] = String(describing: error)
      try? writeEvidence(evidence, environment: environment)
      throw error
    }
  }

  private func makeWindow(frame: CGRect, title: String) -> NSWindow {
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    return window
  }

  private func assertTopmost(
    _ identifier: CGWindowID, query: WindowSnapshotQuery, hitTester: WindowHitTester,
    point: CGPoint
  ) throws {
    try require(
      try query.snapshots().map(\.windowIdentifier) == [identifier],
      "The topmost-limited query returned a different owned window")
    try require(
      hitTester.hitTest(at: point).snapshot?.windowIdentifier == identifier,
      "The CG-frame hit did not return the topmost owned window")
  }

  private struct RawWindow {
    let identifier: CGWindowID
    let frame: CGRect
    let alpha: Double?
  }

  private func rawOwnedWindows(
    identifiers: Set<CGWindowID>, process: pid_t
  ) -> [RawWindow]? {
    guard
      let rows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return rows.compactMap { row in
      guard let number = row[kCGWindowNumber as String] as? NSNumber,
        let identifier = CGWindowID(exactly: number.uint64Value), identifiers.contains(identifier),
        let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
        owner.int64Value == Int64(process),
        let layer = row[kCGWindowLayer as String] as? NSNumber, layer.int64Value == 0,
        let values = row[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: values as CFDictionary),
        frame.width > 0, frame.height > 0,
        [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
      else { return nil }
      return RawWindow(
        identifier: identifier, frame: frame,
        alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
    }
  }

  private func waitFor<Value>(
    failure: OwnedCGFailure, observe: () throws -> Value?
  ) throws -> Value {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let value = try observe() { return value }
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    throw failure
  }

  private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw OwnedCGFailure.semantic(message) }
  }

  private func appendObservation(
    _ phase: String, rows: [WindowSnapshot], to evidence: inout [String: Any]
  ) {
    var observations = evidence["observations"] as? [[String: Any]] ?? []
    observations.append([
      "phase": phase,
      "windows": rows.map { row in
        [
          "identifier": row.windowIdentifier,
          "processIdentifier": row.ownerProcessIdentifier,
          "frame": [
            Double(row.frame.origin.x), Double(row.frame.origin.y), Double(row.frame.width),
            Double(row.frame.height),
          ],
        ] as [String: Any]
      },
    ])
    evidence["observations"] = observations
  }

  private func writeEvidence(_ evidence: [String: Any], environment: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
    print("WINDOW_MANAGEMENT_OWNED_CG " + String(decoding: data, as: UTF8.self))
    if let directory = environment["NAVI_CI_ARTIFACTS"] {
      guard directory.hasPrefix("/") else {
        throw OwnedCGFailure.environment("The owned CG artifact directory must be absolute")
      }
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("window-management-owned-cg.json")
      try data.write(to: destination, options: .atomic)
    }
  }
}

private enum OwnedCGFailure: Error, CustomStringConvertible {
  case environment(String)
  case semantic(String)

  var description: String {
    switch self {
    case .environment(let message): "OWNED_CG_ENVIRONMENT: " + message
    case .semantic(let message): "OWNED_CG_SEMANTIC: " + message
    }
  }
}
