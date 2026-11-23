import CoreGraphics
import WindowManagement

@MainActor
protocol WindowFrameOperationCapturing {
  func captureFrameOperation(for target: WindowTarget) throws -> WindowFrameOperation
}

@MainActor
struct WindowFrameOperation {
  let read: @MainActor () throws -> CGRect
  let setFrame: @MainActor (_ frame: CGRect, _ includingSize: Bool) throws -> Void

  func write(_ frame: CGRect, includingSize: Bool = true) throws {
    try setFrame(frame, includingSize)
  }
}
