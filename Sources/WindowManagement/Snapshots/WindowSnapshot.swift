import CoreGraphics

/// Immutable app-facing representation of a macOS window.
public struct WindowSnapshot: Equatable, Hashable, Sendable, Codable {
  /// Process identifier of the owning application.
  public let ownerProcessIdentifier: pid_t
  /// Core Graphics window identifier.
  public let windowIdentifier: CGWindowID
  /// Display name of the owning application, when available.
  public let ownerName: String?
  /// Bundle identifier of the owning application, when available.
  public let ownerBundleIdentifier: String?
  /// Window title, when available.
  public let title: String?
  /// Standardized window frame in global display coordinates.
  ///
  /// Non-finite components are replaced with finite zero-origin bounds.
  public let frame: CGRect
  /// Rust-owned containment in the snapshot's coordinate space. Maximum edges are excluded.
  public func contains(_ point: CGPoint) -> Bool {
    frame.containsWindowPoint(point)
  }
  /// Creates an immutable window snapshot.
  public init(
    ownerProcessIdentifier: pid_t,
    windowIdentifier: CGWindowID,
    ownerName: String? = nil,
    ownerBundleIdentifier: String? = nil,
    title: String? = nil,
    frame: CGRect
  ) {
    self.ownerProcessIdentifier = ownerProcessIdentifier
    self.windowIdentifier = windowIdentifier
    self.ownerName = ownerName
    self.ownerBundleIdentifier = ownerBundleIdentifier
    self.title = title
    self.frame = frame.finiteStandardized
  }

  /// Restores a snapshot using the same standardized frame as direct construction.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      ownerProcessIdentifier: try container.decode(pid_t.self, forKey: .ownerProcessIdentifier),
      windowIdentifier: try container.decode(CGWindowID.self, forKey: .windowIdentifier),
      ownerName: try container.decodeIfPresent(String.self, forKey: .ownerName),
      ownerBundleIdentifier: try container.decodeIfPresent(
        String.self, forKey: .ownerBundleIdentifier),
      title: try container.decodeIfPresent(String.self, forKey: .title),
      frame: try container.decode(CGRect.self, forKey: .frame))
  }
}
