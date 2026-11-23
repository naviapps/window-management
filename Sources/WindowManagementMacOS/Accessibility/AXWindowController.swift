import ApplicationServices
import CoreGraphics
import WindowManagement

/// Reads and controls live macOS windows through Accessibility.
@MainActor
public struct AXWindowController:
  WindowControlling, WindowRoleProviding, WindowFrameOperationCapturing
{
  private let access: AXWindowAccess
  private let roleResolver = WindowRoleResolver()

  /// Creates a controller backed by the system-wide Accessibility element.
  public init() {
    access = .live()
  }

  init(
    accessibilityClient: AXClient = .live,
    systemWideElement: AXUIElement,
    applicationChecker: any RunningApplicationChecking =
      NSRunningApplicationChecker(),
    windowListProvider: any WindowListProviding = SystemWindowListProvider()
  ) {
    access = AXWindowAccess(
      accessibilityClient: accessibilityClient,
      systemWideElement: systemWideElement,
      applicationChecker: applicationChecker,
      windowListProvider: windowListProvider
    )
  }

  /// Returns the current frame of the target window.
  /// Coordinates start at the primary display's top-left, with y increasing downward.
  public func frame(for target: WindowTarget) throws -> CGRect {
    try translateAXWindowErrors(for: .readFrame) {
      let window = try access.resolver.windowElement(for: target)
      return try frame(of: window)
    }
  }

  /// Sets the frame of the target window.
  /// Uses the same top-left-origin Accessibility coordinates as ``frame(for:)``.
  /// If Accessibility reports a read-only size, neither position nor size is written.
  public func setFrame(_ frame: CGRect, for target: WindowTarget) throws {
    try translateAXWindowErrors(for: .setFrame) {
      let window = try access.resolver.windowElement(for: target)
      try setFrame(frame, on: window)
    }
  }

  func captureFrameOperation(for target: WindowTarget) throws -> WindowFrameOperation {
    let window = try translateAXWindowErrors(for: .readFrame) {
      try access.resolver.windowElement(for: target)
    }
    return WindowFrameOperation(
      read: { try translateAXWindowErrors(for: .readFrame) { try self.frame(of: window) } },
      setFrame: { frame, includingSize in
        try translateAXWindowErrors(for: .setFrame) {
          try self.setFrame(frame, on: window, includingSize: includingSize)
        }
      })
  }

  private func frame(of window: AXUIElement) throws -> CGRect {
    let position = try access.accessibilityClient.attributeCGPoint(.position, of: window)
    let size = try access.accessibilityClient.attributeCGSize(.size, of: window)
    return CGRect(origin: position, size: size)
  }

  private func setFrame(_ frame: CGRect, on window: AXUIElement, includingSize: Bool = true) throws
  {
    let standardizedFrame = frame.standardized
    let positionValue = try standardizedFrame.origin.axValue(using: access.accessibilityClient)
    let sizeValue: AXValue?
    if includingSize {
      sizeValue = try standardizedFrame.size.axValue(using: access.accessibilityClient)
      if access.accessibilityClient.reportsReadOnly(.size, on: window) {
        throw AXWindowError.underlyingAccessibilityError(.attributeUnsupported)
      }
    } else {
      sizeValue = nil
    }
    try access.accessibilityClient.setAttributeValue(.position, value: positionValue, on: window)
    if let sizeValue {
      try access.accessibilityClient.setAttributeValue(.size, value: sizeValue, on: window)
    }
  }

  /// Returns the current app-facing state for the target window.
  public func state(for target: WindowTarget) throws -> WindowState {
    try translateAXWindowErrors(for: .readState) {
      let window = try access.resolver.windowElement(for: target)
      let isMinimized = try access.accessibilityClient.attributeBool(.minimized, of: window)
      let isFullScreen = try access.accessibilityClient.attributeBool(.fullScreen, of: window)
      return WindowState(isMinimized: isMinimized, isFullScreen: isFullScreen)
    }
  }

  /// Requests an ordinary close through the captured window's native close button.
  /// The application may prompt, refuse, or close asynchronously; no termination request is made.
  public func requestClose(_ target: WindowTarget) throws {
    try translateAXWindowErrors(for: .requestClose) {
      let window = try access.resolver.windowElement(for: target)
      guard let button = try access.accessibilityClient.attributeElement(.closeButton, of: window)
      else { throw AXWindowError.unsupportedOperation }
      try access.accessibilityClient.performAction(.press, on: button)
    }
  }

  /// Sets the target window's minimized state.
  public func setMinimized(_ target: WindowTarget, isMinimized: Bool) throws {
    try translateAXWindowErrors(for: .setMinimized) {
      let window = try access.resolver.windowElement(for: target)
      try access.accessibilityClient.setAttributeBool(
        .minimized,
        value: isMinimized,
        on: window)
    }
  }

  /// Sets the target window's full-screen state.
  public func setFullScreen(_ target: WindowTarget, isFullScreen: Bool) throws {
    try translateAXWindowErrors(for: .setFullScreen) {
      let window = try access.resolver.windowElement(for: target)
      try access.accessibilityClient.setAttributeBool(
        .fullScreen,
        value: isFullScreen,
        on: window)
    }
  }

  /// Toggles full screen by reading and writing the same resolved Accessibility window.
  ///
  /// An unavailable state is unsupported. A focus change does not redirect the write,
  /// and acceptance of the write does not imply that the transition has completed.
  public func toggleFullScreen(_ target: WindowTarget) throws {
    try translateAXWindowErrors(for: .setFullScreen) {
      let window = try access.resolver.windowElement(for: target)
      guard let isFullScreen = try access.accessibilityClient.attributeBool(.fullScreen, of: window)
      else { throw AXWindowError.unsupportedOperation }
      try access.accessibilityClient.setAttributeBool(
        .fullScreen, value: !isFullScreen, on: window)
    }
  }

  /// Raises the target window above other windows when the system allows it.
  public func raise(_ target: WindowTarget) throws {
    try translateAXWindowErrors(for: .raise) {
      let window = try access.resolver.windowElement(for: target)
      try access.accessibilityClient.performAction(.raise, on: window)
    }
  }

  /// Lowers the target window when the system exposes the Accessibility action.
  public func lower(_ target: WindowTarget) throws {
    try translateAXWindowErrors(for: .lower) {
      let window = try access.resolver.windowElement(for: target)
      try access.accessibilityClient.performAction(.lower, on: window)
    }
  }

  /// Returns the app-facing role classification for the target window.
  public func role(for target: WindowTarget) throws -> WindowRole {
    try translateAXWindowErrors(for: .readRole) {
      let window = try access.resolver.windowElement(for: target)
      let accessibilityRole = try access.accessibilityClient.attributeString(.role, of: window)
      let accessibilitySubrole = try access.accessibilityClient.attributeString(
        .subrole, of: window)
      return roleResolver.resolve(
        accessibilityRole: accessibilityRole,
        accessibilitySubrole: accessibilitySubrole
      )
    }
  }
}
