/// Requests window close, state and ordering changes without direct frame writes.
public protocol WindowCommandControlling: Sendable {
  /// Requests an ordinary close of one window, allowing the application to prompt or refuse.
  /// Acceptance does not confirm closure or saved data.
  @MainActor
  func requestClose(_ target: WindowTarget) throws

  /// Sets minimized state for a target window.
  @MainActor
  func setMinimized(_ target: WindowTarget, isMinimized: Bool) throws

  /// Sets full-screen state for a target window.
  @MainActor
  func setFullScreen(_ target: WindowTarget, isFullScreen: Bool) throws

  /// Raises a target window.
  @MainActor
  func raise(_ target: WindowTarget) throws

  /// Lowers a target window.
  @MainActor
  func lower(_ target: WindowTarget) throws
}
