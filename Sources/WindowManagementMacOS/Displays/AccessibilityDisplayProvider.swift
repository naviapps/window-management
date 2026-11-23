import CoreGraphics
import WindowManagement

/// Adapts AppKit display geometry for Accessibility frame control.
@MainActor
struct AccessibilityDisplayProvider: DisplayProviding {
  private let appKitDisplayProvider: any DisplayProviding

  init(
    appKitDisplayProvider: any DisplayProviding = AppKitDisplayProvider()
  ) {
    self.appKitDisplayProvider = appKitDisplayProvider
  }

  func displays() -> [Display] {
    let displays = appKitDisplayProvider.displays()
    // AppKitDisplayProvider preserves NSScreen.screens order: the primary display is first.
    // Use this same snapshot for the origin and all display frames.
    guard let primary = displays.first else { return [] }
    let topY = primary.frame.maxY
    return displays.map { display in
      Display(
        displayIdentifier: display.displayIdentifier,
        frame: accessibilityFrame(display.frame, primaryTopY: topY),
        visibleFrame: accessibilityFrame(display.visibleFrame, primaryTopY: topY),
        isMain: display.isMain
      )
    }
  }

  private func accessibilityFrame(_ frame: CGRect, primaryTopY: CGFloat) -> CGRect {
    CGRect(x: frame.minX, y: primaryTopY - frame.maxY, width: frame.width, height: frame.height)
  }
}
