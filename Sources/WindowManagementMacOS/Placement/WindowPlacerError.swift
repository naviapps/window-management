import WindowManagement

/// Errors thrown by live window placement operations.
public enum WindowPlacerError: Error, Equatable, Hashable, Sendable {
  /// The requested display target could not be resolved.
  case displayNotFound(DisplayTarget)
}
