import CoreGraphics
import Foundation
import WindowManagement
import WindowManagementMacOS

private struct AcceptanceFailure: Error {
  let message: String
}

private func require(_ condition: Bool, _ message: String) throws {
  guard condition else { throw AcceptanceFailure(message: message) }
}

@MainActor
private final class SyntheticFrameController: WindowFrameControlling {
  private let target: WindowTarget
  private(set) var storedFrame: CGRect
  private(set) var readCount = 0
  private(set) var writeCount = 0

  init(target: WindowTarget, frame: CGRect) {
    self.target = target
    storedFrame = frame
  }

  func frame(for target: WindowTarget) throws -> CGRect {
    try require(target == self.target, "The placer selected another synthetic window")
    readCount += 1
    return storedFrame
  }

  func setFrame(_ frame: CGRect, for target: WindowTarget) throws {
    try require(target == self.target, "The placer wrote another synthetic window")
    writeCount += 1
    storedFrame = frame
  }
}

private struct SyntheticDisplays: DisplayProviding {
  let values: [Display]

  @MainActor
  func displays() -> [Display] {
    values
  }
}

@main
struct WindowManagementConsumer {
  @MainActor
  static func main() throws {
    let target = WindowTarget.windowIdentifier(42)
    let original = CGRect(x: 20, y: 30, width: 200, height: 120)
    let area = CGRect(x: 0, y: 20, width: 800, height: 560)
    let savedDisplay = Data(
      #"{"displayIdentifier":7,"frame":[[800,600],[-800,-600]],"visibleFrame":[[800,580],[-800,-560]],"isMain":true}"#
        .utf8)
    let display = try JSONDecoder().decode(Display.self, from: savedDisplay)
    try require(display.visibleFrame == area, "The installed display lost its usable bounds")
    let placement = WindowPlacement.grid(
      columns: 2, rows: 1, column: 1, row: 0, columnSpan: 1, rowSpan: 1)
    let expected = CGRect(x: 400, y: 20, width: 400, height: 560)
    try require(
      WindowPlacementCalculator.frame(for: placement, in: area) == expected,
      "The installed native geometry engine returned another frame")
    let smallest = CGFloat.leastNonzeroMagnitude
    let tinyArea = CGRect(x: 0, y: 0, width: 3 * smallest, height: 7 * smallest)
    let insetFrame = WindowPlacementCalculator.frame(for: .fill, in: tinyArea, inset: 1)
    try require(
      insetFrame.origin == CGPoint(x: 2 * smallest, y: 2 * smallest)
        && insetFrame.size == CGSize(width: 0, height: 4 * smallest),
      "The installed inset failed to collapse the shorter dimension")
    let request = WindowPlacementRequest(placement: placement)
    try require(
      WindowRequestCodec.decodePlacement(WindowRequestCodec.encode(request)) == request,
      "The installed request codec changed a typed placement")
    try require(
      DisplaySelector.index(containing: .init(x: 0, y: 20), in: [display]) == 0,
      "The installed package did not resolve a display point")
    let mirrored = Display(
      displayIdentifier: 9, frame: CGRect(x: -0.0, y: -0.0, width: 800, height: 600),
      visibleFrame: area)
    try require(
      DisplaySelector.display(
        for: .point(.init(x: 10, y: 10)), windowFrame: original, in: [display, mirrored],
        fallback: .none) == display,
      "The installed package did not break a signed-zero display tie by identifier")

    let savedSnapshot = Data(
      #"{"ownerProcessIdentifier":123,"windowIdentifier":42,"frame":[[220,150],[-200,-120]]}"#.utf8)
    let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: savedSnapshot)
    try require(
      snapshot.frame.origin == original.origin && snapshot.contains(original.origin),
      "The installed snapshot did not restore its canonical bounds")
    let filter = WindowSnapshotFilter(
      includedOwnerProcessIdentifiers: [123, .min], includedWindowIdentifiers: [42, .max])
    try require(filter.includes(snapshot), "The installed snapshot filter rejected its target")
    let restored = try WindowSnapshotFilter(jsonData: filter.jsonData)
    try require(restored == filter, "The installed filter lost its canonical JSON")
    try require(
      restored.includedOwnerProcessIdentifiers == [123, .min]
        && restored.includedWindowIdentifiers == [42, .max],
      "The installed filter narrowed shared numeric identifiers")
    do {
      _ = try WindowSnapshotFilter(jsonData: Data(#"{"unknown":true}"#.utf8))
      throw AcceptanceFailure(message: "The filter accepted an unknown JSON field")
    } catch let error as WindowRequestCodecError {
      try require(
        !error.localizedDescription.isEmpty, "The public decode failure has no diagnostic")
    }

    let frames = SyntheticFrameController(target: target, frame: original)
    let placer = WindowPlacer(
      frameController: frames, displayProvider: SyntheticDisplays(values: [display]))
    try placer.place(placement, for: target, displayFallback: .none)
    try require(frames.storedFrame == expected, "The AppKit facade lost the planned frame")
    try require(frames.readCount == 1 && frames.writeCount == 1, "Unexpected provider calls")

    let unavailable = WindowPlacer(
      frameController: frames, displayProvider: SyntheticDisplays(values: []))
    do {
      try unavailable.place(.fill, for: target)
      throw AcceptanceFailure(message: "Placement without any display was accepted")
    } catch let error as WindowPlacerError {
      try require(
        error == .displayNotFound(.containingWindow), "The failure lost its public type")
    }
    try require(
      frames.storedFrame == expected && frames.readCount == 1 && frames.writeCount == 1,
      "Rejected placement touched the synthetic window")
    print("Standalone WindowManagement and WindowManagementMacOS acceptance passed.")
  }
}
