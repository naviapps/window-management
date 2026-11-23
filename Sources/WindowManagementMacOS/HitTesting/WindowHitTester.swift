import CoreGraphics
import WindowManagement

/// System-backed hit tester for selecting the topmost matching window at a point.
/// A native window with zero overall alpha does not count as a hit.
public struct WindowHitTester: WindowHitTesting, Sendable {
  private let request: WindowListRequest
  private let listProvider: any WindowListProviding
  private let pointTransform: @Sendable (CGPoint) -> CGPoint
  private let mapper: WindowListSnapshotMapper

  /// Creates a hit tester for normal-level windows using the system window list.
  public init(
    pointTransform: @escaping @Sendable (CGPoint) -> CGPoint = { $0 },
    filter: WindowSnapshotFilter = .init()
  ) {
    self.init(
      listProvider: SystemWindowListProvider(),
      pointTransform: pointTransform,
      filter: filter
    )
  }

  /// Creates a hit tester that only considers windows at the specified Core Graphics levels.
  ///
  /// Candidates are still checked in the system list's front-to-back order. A hit
  /// uses the window's bounds; the list cannot tell whether the window accepts
  /// mouse input or whether a point falls in a transparent area.
  public init(
    windowLevels: Set<CGWindowLevel>,
    pointTransform: @escaping @Sendable (CGPoint) -> CGPoint = { $0 },
    filter: WindowSnapshotFilter = .init()
  ) {
    self.init(
      listProvider: SystemWindowListProvider(),
      pointTransform: pointTransform,
      filter: filter,
      windowLayers: windowLevels
    )
  }

  init(
    request: WindowListRequest = .onScreenWindows,
    listProvider: any WindowListProviding,
    pointTransform: @escaping @Sendable (CGPoint) -> CGPoint = { $0 },
    ownerBundleIdentifierProvider: any WindowOwnerBundleIdentifierProviding =
      NSRunningApplicationBundleIdentifierProvider(),
    filter: WindowSnapshotFilter = .init(),
    windowLayers: Set<CGWindowLevel> = [0]
  ) {
    self.request = request
    self.listProvider = listProvider
    self.pointTransform = pointTransform
    mapper = WindowListSnapshotMapper(
      ownerBundleIdentifierProvider: ownerBundleIdentifierProvider,
      filter: filter,
      windowLayers: windowLayers
    )
  }

  /// Returns the topmost matching window at the given point.
  public func hitTest(at point: CGPoint) -> WindowHitTestResult {
    guard let windowList = listProvider.windowList(for: request) else {
      return .miss(.sourceUnavailable)
    }

    let transformedPoint = pointTransform(point)
    for entry in windowList {
      if let snapshot = mapper.snapshot(from: entry, containing: transformedPoint) {
        return .hit(snapshot)
      }
    }
    return .miss(.noMatchingWindowAtPoint)
  }
}
