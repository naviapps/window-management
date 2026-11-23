import CoreGraphics
import Foundation

struct WindowListEntry: Sendable {
  let layer: CGWindowLevel?
  let frame: CGRect?
  let ownerProcessIdentifier: pid_t?
  let windowIdentifier: CGWindowID?
  let ownerName: String?
  let title: String?

  init(
    layer: CGWindowLevel? = nil,
    frame: CGRect? = nil,
    ownerProcessIdentifier: pid_t? = nil,
    windowIdentifier: CGWindowID? = nil,
    ownerName: String? = nil,
    title: String? = nil
  ) {
    self.layer = layer
    self.frame = frame
    self.ownerProcessIdentifier = ownerProcessIdentifier
    self.windowIdentifier = windowIdentifier
    self.ownerName = ownerName
    self.title = title
  }
}

/// Retains one native dictionary or immutable test entry for synchronous query traversal.
enum WindowListCandidate {
  case entry(WindowListEntry)
  case coreGraphics(NSDictionary)

  var layer: CGWindowLevel? {
    switch self {
    case .entry(let entry): entry.layer
    case .coreGraphics(let values): Self.number(values[kCGWindowLayer as String]) as? CGWindowLevel
    }
  }

  var frame: CGRect? {
    switch self {
    case .entry(let entry): entry.frame
    case .coreGraphics(let values):
      (values[kCGWindowBounds as String] as? NSDictionary)
        .flatMap(CGRect.init(dictionaryRepresentation:))
    }
  }

  var isFullyTransparent: Bool {
    guard case .coreGraphics(let values) = self,
      let alpha = Self.number(values[kCGWindowAlpha as String])
    else { return false }
    return alpha.doubleValue == 0
  }

  var ownerProcessIdentifier: pid_t? {
    switch self {
    case .entry(let entry): entry.ownerProcessIdentifier
    case .coreGraphics(let values):
      if let process = Self.number(values[kCGWindowOwnerPID as String]) as? pid_t, process >= 0 {
        process
      } else {
        nil
      }
    }
  }

  var windowIdentifier: CGWindowID? {
    switch self {
    case .entry(let entry): entry.windowIdentifier
    case .coreGraphics(let values):
      Self.number(values[kCGWindowNumber as String]) as? CGWindowID
    }
  }

  var ownerName: String? {
    switch self {
    case .entry(let entry): entry.ownerName
    case .coreGraphics(let values): values[kCGWindowOwnerName as String] as? String
    }
  }

  var title: String? {
    switch self {
    case .entry(let entry): entry.title
    case .coreGraphics(let values): values[kCGWindowName as String] as? String
    }
  }

  private static func number(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }

    return number
  }
}
