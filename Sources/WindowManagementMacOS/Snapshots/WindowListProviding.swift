import CoreGraphics
import Foundation

protocol WindowListProviding: Sendable {
  func windowList(for request: WindowListRequest) -> (any Sequence<WindowListCandidate>)?
}

struct SystemWindowListProvider: WindowListProviding {
  func windowList(for request: WindowListRequest) -> (any Sequence<WindowListCandidate>)? {
    guard
      let windowInfo = CGWindowListCopyWindowInfo(request.options, request.windowIdentifier)
        as? [NSDictionary]
    else { return nil }
    return windowInfo.lazy.map(WindowListCandidate.coreGraphics)
  }
}
