import CoreGraphics
import Foundation

struct WindowListEntry: Sendable {
  let layer: Int?
  let frame: CGRect?
  let ownerProcessIdentifier: pid_t?
  let windowIdentifier: CGWindowID?
  let ownerName: String?
  let title: String?

  init(
    layer: Int? = nil,
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

  var layer: Int? {
    switch self {
    case .entry(let entry): entry.layer
    case .coreGraphics(let values): Self.layer(from: values[CGWindowInfoKey.layer.dictionaryName])
    }
  }

  var frame: CGRect? {
    switch self {
    case .entry(let entry): entry.frame
    case .coreGraphics(let values):
      (values[CGWindowInfoKey.bounds.dictionaryName] as? NSDictionary)
        .flatMap(CGRect.init(dictionaryRepresentation:))
    }
  }

  var isFullyTransparent: Bool {
    guard case .coreGraphics(let values) = self,
      let alpha = values[CGWindowInfoKey.alpha.dictionaryName] as? NSNumber,
      CFGetTypeID(alpha) != CFBooleanGetTypeID()
    else { return false }
    return alpha.doubleValue == 0
  }

  var ownerProcessIdentifier: pid_t? {
    switch self {
    case .entry(let entry): entry.ownerProcessIdentifier
    case .coreGraphics(let values):
      Self.processIdentifier(from: values[CGWindowInfoKey.ownerProcessIdentifier.dictionaryName])
    }
  }

  var windowIdentifier: CGWindowID? {
    switch self {
    case .entry(let entry): entry.windowIdentifier
    case .coreGraphics(let values):
      Self.windowIdentifier(from: values[CGWindowInfoKey.windowIdentifier.dictionaryName])
    }
  }

  var ownerName: String? {
    switch self {
    case .entry(let entry): entry.ownerName
    case .coreGraphics(let values): values[CGWindowInfoKey.ownerName.dictionaryName] as? String
    }
  }

  var title: String? {
    switch self {
    case .entry(let entry): entry.title
    case .coreGraphics(let values): values[CGWindowInfoKey.title.dictionaryName] as? String
    }
  }

  private static func layer(from value: Any?) -> Int? {
    guard let integer = integerValue(from: value),
      integer >= Int64(Int.min),
      integer <= Int64(Int.max)
    else {
      return nil
    }
    return Int(integer)
  }

  private static func processIdentifier(from value: Any?) -> pid_t? {
    guard let integer = integerValue(from: value),
      integer >= 0,
      integer <= Int64(Int32.max)
    else {
      return nil
    }
    return pid_t(integer)
  }

  private static func windowIdentifier(from value: Any?) -> CGWindowID? {
    guard let integer = integerValue(from: value),
      integer >= 0,
      integer <= Int64(UInt32.max)
    else {
      return nil
    }
    return CGWindowID(integer)
  }

  private static func integerValue(from value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }

    let doubleValue = number.doubleValue
    guard doubleValue.isFinite,
      doubleValue.rounded(.towardZero) == doubleValue,
      doubleValue >= Double(Int64.min),
      doubleValue <= Double(Int64.max)
    else {
      return nil
    }
    return number.int64Value
  }
}

enum CGWindowInfoKey {
  case alpha
  case bounds
  case layer
  case ownerName
  case ownerProcessIdentifier
  case title
  case windowIdentifier
}

extension CGWindowInfoKey {
  var dictionaryName: String {
    switch self {
    case .alpha:
      kCGWindowAlpha as String
    case .bounds:
      kCGWindowBounds as String
    case .layer:
      kCGWindowLayer as String
    case .ownerName:
      kCGWindowOwnerName as String
    case .ownerProcessIdentifier:
      kCGWindowOwnerPID as String
    case .title:
      kCGWindowName as String
    case .windowIdentifier:
      kCGWindowNumber as String
    }
  }
}
