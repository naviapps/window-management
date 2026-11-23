import CoreGraphics

/// Immutable app-facing representation of a macOS display.
public struct Display: Equatable, Hashable, Sendable, Codable {
  /// Core Graphics display identifier, when available.
  public let displayIdentifier: CGDirectDisplayID?
  /// Standardized full display frame.
  public let frame: CGRect
  /// Standardized visible frame excluding system-reserved areas such as the menu bar and Dock.
  public let visibleFrame: CGRect
  /// Whether this is the system's primary display.
  public let isMain: Bool

  /// Creates a display value.
  public init(
    displayIdentifier: CGDirectDisplayID? = nil,
    frame: CGRect,
    visibleFrame: CGRect,
    isMain: Bool = false
  ) {
    self.displayIdentifier = displayIdentifier
    self.frame = frame.finiteStandardized
    self.visibleFrame = visibleFrame.finiteStandardized
    self.isMain = isMain
  }

  /// Restores a display using the same Rust geometry as direct construction.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      displayIdentifier: try container.decodeIfPresent(
        CGDirectDisplayID.self, forKey: .displayIdentifier),
      frame: try container.decode(CGRect.self, forKey: .frame),
      visibleFrame: try container.decode(CGRect.self, forKey: .visibleFrame),
      isMain: try container.decode(Bool.self, forKey: .isMain))
  }

  /// Returns the frame for a requested display area.
  public func frame(for area: DisplayArea) -> CGRect {
    switch area {
    case .full:
      return frame
    case .visible:
      return visibleFrame
    }
  }
}
