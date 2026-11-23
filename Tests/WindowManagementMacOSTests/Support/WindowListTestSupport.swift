import CoreGraphics
import Foundation
import WindowManagement
import os

@testable import WindowManagementMacOS

final class WindowListProviderSpy: WindowListProviding {
  let entries: [WindowListEntry]?
  private let requestsStorage = OSAllocatedUnfairLock(initialState: [WindowListRequest]())

  var requests: [WindowListRequest] {
    requestsStorage.withLock { $0 }
  }

  init(entries: [WindowListEntry]?) {
    self.entries = entries
  }

  func windowList(for request: WindowListRequest) -> (any Sequence<WindowListCandidate>)? {
    requestsStorage.withLock {
      $0.append(request)
    }
    return entries?.lazy.map(WindowListCandidate.entry)
  }
}

/// Dictionaries are immutable fixture values; request and key observations are locked.
final class NativeWindowListProviderSpy: WindowListProviding, @unchecked Sendable {
  private let windowInfo: [NSDictionary]?
  private let requestsStorage = OSAllocatedUnfairLock(initialState: [WindowListRequest]())

  var requests: [WindowListRequest] { requestsStorage.withLock { $0 } }

  init(windowInfo: [NSDictionary]?) { self.windowInfo = windowInfo }

  func windowList(for request: WindowListRequest) -> (any Sequence<WindowListCandidate>)? {
    requestsStorage.withLock { $0.append(request) }
    return windowInfo?.lazy.map(WindowListCandidate.coreGraphics)
  }
}

final class ChangingWindowListProvider: WindowListProviding {
  private let entriesStorage: OSAllocatedUnfairLock<[WindowListEntry]?>
  private let requestsStorage = OSAllocatedUnfairLock(initialState: [WindowListRequest]())

  var requests: [WindowListRequest] { requestsStorage.withLock { $0 } }

  init(entries: [WindowListEntry]?) {
    entriesStorage = OSAllocatedUnfairLock(initialState: entries)
  }

  func replaceEntries(with entries: [WindowListEntry]?) {
    entriesStorage.withLock { $0 = entries }
  }

  func windowList(for request: WindowListRequest) -> (any Sequence<WindowListCandidate>)? {
    requestsStorage.withLock { $0.append(request) }
    return entriesStorage.withLock { $0 }?.lazy.map(WindowListCandidate.entry)
  }
}

struct RecordingWindowBundleIdentifierProvider: WindowOwnerBundleIdentifierProviding {
  private let requestsStorage = OSAllocatedUnfairLock(initialState: [pid_t]())
  private let response: @Sendable (pid_t) -> String?

  var requests: [pid_t] { requestsStorage.withLock { $0 } }

  init(response: @escaping @Sendable (pid_t) -> String? = { _ in "com.example.app" }) {
    self.response = response
  }

  func bundleIdentifier(forProcessIdentifier processIdentifier: pid_t) -> String? {
    requestsStorage.withLock { $0.append(processIdentifier) }
    return response(processIdentifier)
  }
}

final class ObservedWindowInfo: NSDictionary {
  private let values: [String: Any]
  private let readsStorage = OSAllocatedUnfairLock(initialState: [String]())

  var lookedUpKeys: [String] { readsStorage.withLock { $0 } }

  init(values: [String: Any]) {
    self.values = values
    super.init()
  }

  override init() { fatalError("Use the fixture initializer") }

  override init(
    objects _: UnsafePointer<AnyObject>!, forKeys _: UnsafePointer<NSCopying>!, count _: Int
  ) { fatalError("Use the fixture initializer") }

  required init?(coder _: NSCoder) { fatalError("Use the fixture initializer") }

  override var count: Int { values.count }

  override func keyEnumerator() -> NSEnumerator {
    (Array(values.keys) as NSArray).objectEnumerator()
  }

  override func object(forKey key: Any) -> Any? {
    guard let key = key as? String else { return nil }
    readsStorage.withLock { $0.append(key) }
    return values[key]
  }
}

func makeRawWindowInfo(
  layer: NSNumber = 0,
  frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
  ownerProcessIdentifier: NSNumber = 123,
  windowIdentifier: NSNumber = 456,
  ownerName: String = "ExampleApp",
  title: String = "Main",
  alpha: NSNumber? = nil
) -> [String: Any] {
  var values: [String: Any] = [
    kCGWindowLayer as String: layer,
    kCGWindowBounds as String: frame.dictionaryRepresentation,
    kCGWindowOwnerPID as String: ownerProcessIdentifier,
    kCGWindowNumber as String: windowIdentifier,
    kCGWindowOwnerName as String: ownerName,
    kCGWindowName as String: title,
  ]
  if let alpha { values[kCGWindowAlpha as String] = alpha }
  return values
}

struct WindowOwnerBundleIdentifierProvidingStub: WindowOwnerBundleIdentifierProviding {
  let bundleIdentifier: String?

  func bundleIdentifier(forProcessIdentifier _: pid_t) -> String? {
    bundleIdentifier
  }
}

func makeWindowEntry(
  layer: Int,
  frame: CGRect,
  ownerProcessIdentifier: Int32?,
  windowIdentifier: UInt32? = 12345
) -> WindowListEntry {
  let processIdentifier = ownerProcessIdentifier.map { pid_t($0) }
  let cgWindowIdentifier = windowIdentifier.map { CGWindowID($0) }

  return WindowListEntry(
    layer: layer,
    frame: frame,
    ownerProcessIdentifier: processIdentifier,
    windowIdentifier: cgWindowIdentifier,
    ownerName: "ExampleApp",
    title: "Main"
  )
}
