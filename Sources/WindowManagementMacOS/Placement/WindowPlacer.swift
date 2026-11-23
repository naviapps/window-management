import CoreGraphics
import WindowManagement

/// Places live macOS windows using WindowManagement placement values and display providers.
@MainActor
public struct WindowPlacer {
  private let frameController: any WindowFrameControlling
  private let displayProvider: any DisplayProviding
  private let captureFrameOperation: @MainActor (WindowTarget) throws -> WindowFrameOperation

  /// Creates a placer backed by Accessibility window frame control and AppKit displays.
  ///
  /// Display frames are converted to Accessibility coordinates: the primary display's top-left
  /// corner is the origin, and y increases downward. Grid row zero is at the top of the area.
  public init() {
    self.init(
      frameController: AXWindowController(),
      displayProvider: AccessibilityDisplayProvider()
    )
  }

  /// Creates a placer with caller-supplied frame and display providers.
  ///
  /// Both providers and any point display target must use the same coordinate space. No conversion
  /// is applied to caller-supplied providers.
  public init(
    frameController: any WindowFrameControlling,
    displayProvider: any DisplayProviding
  ) {
    self.frameController = frameController
    self.displayProvider = displayProvider
    if let capturing = frameController as? any WindowFrameOperationCapturing {
      captureFrameOperation = { try capturing.captureFrameOperation(for: $0) }
    } else {
      captureFrameOperation = { target in
        WindowFrameOperation(
          read: { try frameController.frame(for: target) },
          setFrame: { frame, _ in try frameController.setFrame(frame, for: target) })
      }
    }
  }

  /// Places a target window according to a placement value.
  ///
  /// Unresolved display targets use the first ordered display by default. Missing displays always
  /// throw ``WindowPlacerError/displayNotFound(_:)``. Pass
  /// `DisplayFallback.none` to also reject an unmatched target when displays exist.
  public func place(
    _ placement: WindowPlacement,
    for target: WindowTarget,
    display displayTarget: DisplayTarget = .containingWindow,
    area: DisplayArea = .visible,
    inset: CGFloat = 0,
    displayFallback: DisplayFallback = .firstDisplay
  ) throws {
    try place(
      .init(placement: placement, display: displayTarget, area: area, inset: inset), for: target,
      displayFallback: displayFallback)
  }

  /// Places a target using a reusable request and Rust-owned display/frame resolution.
  public func place(
    _ request: WindowPlacementRequest, for target: WindowTarget,
    displayFallback: DisplayFallback = .firstDisplay
  ) throws {
    let displays = displayProvider.displays()
    guard !displays.isEmpty else { throw WindowPlacerError.displayNotFound(request.display) }
    let operation =
      request.display == .containingWindow ? try captureFrameOperation(target) : nil
    let window = try operation?.read() ?? .zero
    guard
      let frame = WindowRequestResolver.placement(
        request, windowFrame: window, in: displays, fallback: displayFallback)
    else {
      throw WindowPlacerError.displayNotFound(request.display)
    }
    if let operation {
      try operation.write(frame, includingSize: frame.standardized.size != window.standardized.size)
    } else {
      try frameController.setFrame(frame, for: target)
    }
  }

  /// Moves a target window to the next or previous ordered display.
  ///
  /// The source display has the greatest positive overlap with the current window frame.
  /// When the window is already on the only display, the operation leaves it unchanged.
  /// A window outside all known displays is treated as if it were on the first ordered display by
  /// default. Missing displays always throw ``WindowPlacerError/displayNotFound(_:)``. Pass
  /// `DisplayFallback.none` to also reject a window outside every known display.
  public func moveToAdjacentDisplay(
    _ direction: DisplayCycleDirection,
    for target: WindowTarget,
    preservingRelativePosition: Bool = true,
    displayFallback: DisplayFallback = .firstDisplay
  ) throws {
    try moveToAdjacentDisplay(
      .init(direction: direction, preservesRelativePosition: preservingRelativePosition),
      for: target, displayFallback: displayFallback)
  }

  /// Moves a target using a reusable request and Rust-owned movement resolution.
  public func moveToAdjacentDisplay(
    _ request: WindowMoveRequest, for target: WindowTarget,
    displayFallback: DisplayFallback = .firstDisplay
  ) throws {
    let displays = displayProvider.displays()
    guard !displays.isEmpty else { throw WindowPlacerError.displayNotFound(.containingWindow) }
    let operation = try captureFrameOperation(target)
    let window = try operation.read()
    guard
      let plan = WindowRequestResolver.movementPlan(
        request, windowFrame: window, in: displays, fallback: displayFallback)
    else {
      throw WindowPlacerError.displayNotFound(.containingWindow)
    }
    guard plan.requiresFrameWrite else { return }
    let frame = plan.frame
    try operation.write(frame, includingSize: frame.standardized.size != window.standardized.size)
  }
}
