import CoreGraphics
import WindowManagement

struct WindowListSnapshotMapper: Sendable {
  private let ownerBundleIdentifierProvider: any WindowOwnerBundleIdentifierProviding
  private let filter: WindowSnapshotFilter
  private let windowLayers: Set<CGWindowLevel>

  init(
    ownerBundleIdentifierProvider: any WindowOwnerBundleIdentifierProviding =
      NSRunningApplicationBundleIdentifierProvider(),
    filter: WindowSnapshotFilter = .init(),
    windowLayers: Set<CGWindowLevel> = [0]
  ) {
    self.ownerBundleIdentifierProvider = ownerBundleIdentifierProvider
    self.filter = filter
    self.windowLayers = windowLayers
  }

  func snapshot(
    from entry: WindowListCandidate, containing point: CGPoint? = nil,
    matchedWindowIdentifier: CGWindowID? = nil
  ) -> WindowSnapshot? {
    guard let layer = entry.layer, windowLayers.contains(layer),
      let rawBounds = entry.frame, rawBounds.hasFiniteComponents
    else {
      return nil
    }
    if let point {
      guard rawBounds.containsWindowPoint(point), !entry.isFullyTransparent else { return nil }
    }
    guard let ownerProcessIdentifier = entry.ownerProcessIdentifier,
      let windowIdentifier = matchedWindowIdentifier ?? entry.windowIdentifier
    else { return nil }

    let match = filter.matchIdentity(
      windowIdentifier: windowIdentifier, ownerProcessIdentifier: ownerProcessIdentifier)
    guard match != .excluded else { return nil }
    let identifier = ownerBundleIdentifierProvider.bundleIdentifier(
      forProcessIdentifier: ownerProcessIdentifier)
    guard
      match == .included
        || filter.includes(
          windowIdentifier: windowIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
          ownerApplicationIdentifier: identifier)
    else { return nil }

    return WindowSnapshot(
      ownerProcessIdentifier: ownerProcessIdentifier,
      windowIdentifier: windowIdentifier,
      ownerName: entry.ownerName,
      ownerBundleIdentifier: identifier,
      title: entry.title,
      frame: rawBounds
    )
  }
}

extension CGRect {
  fileprivate var hasFiniteComponents: Bool {
    origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
  }
}
