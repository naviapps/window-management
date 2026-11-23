import AppKit
import CoreGraphics
import WindowManagement

/// Display provider backed by `NSScreen`.
@MainActor
public struct AppKitDisplayProvider: DisplayProviding {
  /// Creates an AppKit display provider.
  public init() {}

  /// Returns current AppKit displays as `Display` values.
  /// Frames retain AppKit coordinates, with the origin at the primary display's bottom-left.
  /// The first screen in the AppKit snapshot is the primary display, regardless of keyboard focus.
  public func displays() -> [Display] {
    NSScreen.screens.enumerated().map { index, screen in
      let displayNumber = screen.deviceDescription[Self.displayNumberKey] as? NSNumber
      let displayIdentifier = displayNumber.map { CGDirectDisplayID($0.uint32Value) }
      return Display(
        displayIdentifier: displayIdentifier,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame,
        isMain: index == 0
      )
    }
  }

  private static let displayNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
}
