import ApplicationServices
import WindowManagement
import XCTest

@testable import WindowManagementMacOS

@MainActor
final class AXWindowControllerCommandTests: XCTestCase {
  func testClosePressesOnlyTheCapturedWindowsCloseButton() throws {
    let fixture = FocusedWindowAXFixture()
    let closeButton = AXUIElementCreateApplication(getpid() + 2)
    var windowLookups = 0
    var presses = 0
    let client = fixture.accessibilityClient(
      additionalHandler: { element, attribute, value in
        XCTAssertTrue(CFEqual(element, fixture.windowElement))
        XCTAssertEqual(attribute as String, kAXCloseButtonAttribute as String)
        windowLookups += 1
        value.pointee = closeButton
        return .success
      },
      performAction: { element, action in
        XCTAssertTrue(CFEqual(element, closeButton))
        XCTAssertEqual(action as String, kAXPressAction as String)
        presses += 1
        return .success
      })

    try fixture.commandController(accessibilityClient: client).requestClose(.focused)

    XCTAssertEqual(windowLookups, 1)
    XCTAssertEqual(presses, 1)
  }

  func testCloseWithNoButtonIsUnsupportedAndNeverPressesAnythingElse() {
    let fixture = FocusedWindowAXFixture()
    let client = fixture.accessibilityClient(performAction: { _, _ in
      XCTFail("Missing close button must not trigger another native action")
      return .success
    })
    XCTAssertThrowsError(
      try fixture.commandController(accessibilityClient: client).requestClose(.focused)
    ) {
      XCTAssertEqual(
        $0 as? WindowAccessibilityError, .unsupportedAccessibilityOperation(.requestClose))
    }
  }

  func testClosePropagatesNativeFailureWithoutRetryingOrSelectingAnotherWindow() {
    let fixture = FocusedWindowAXFixture()
    let closeButton = AXUIElementCreateApplication(getpid() + 2)
    for failure: AXError in [.cannotComplete, .invalidUIElement, .actionUnsupported] {
      var presses = 0
      let client = fixture.accessibilityClient(
        additionalHandler: { _, _, value in
          value.pointee = closeButton
          return .success
        },
        performAction: { element, _ in
          XCTAssertTrue(CFEqual(element, closeButton))
          presses += 1
          return failure
        })
      XCTAssertThrowsError(
        try fixture.commandController(accessibilityClient: client).requestClose(.focused))
      XCTAssertEqual(presses, 1)
    }
  }

  func testSetMinimizedWritesMinimizedAttribute() throws {
    let fixture = FocusedWindowAXFixture()

    var writes: [BooleanAttributeWrite] = []
    let accessibilityClient = fixture.accessibilityClient(setAttributeValue: {
      element, attribute, value in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      guard CFGetTypeID(value) == CFBooleanGetTypeID(),
        let boolValue = value as? Bool
      else {
        XCTFail("Expected Boolean attribute value")
        return .success
      }
      writes.append(BooleanAttributeWrite(attribute: attribute as String, value: boolValue))
      return .success
    })

    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    try controller.setMinimized(.focused, isMinimized: true)
    try controller.setMinimized(.focused, isMinimized: false)

    XCTAssertEqual(
      writes,
      [
        BooleanAttributeWrite(
          attribute: AXWindowAttribute.minimized.accessibilityName,
          value: true),
        BooleanAttributeWrite(
          attribute: AXWindowAttribute.minimized.accessibilityName,
          value: false),
      ])
  }

  func testSetFullScreenWritesFullScreenAttribute() throws {
    let fullScreenAttribute = AXWindowAttribute.fullScreen.accessibilityName

    let fixture = FocusedWindowAXFixture()

    var writes: [BooleanAttributeWrite] = []
    let accessibilityClient = fixture.accessibilityClient(setAttributeValue: {
      element, attribute, value in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      guard CFGetTypeID(value) == CFBooleanGetTypeID(),
        let boolValue = value as? Bool
      else {
        XCTFail("Expected Boolean attribute value")
        return .success
      }
      writes.append(BooleanAttributeWrite(attribute: attribute as String, value: boolValue))
      return .success
    })

    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    try controller.setFullScreen(.focused, isFullScreen: true)
    try controller.setFullScreen(.focused, isFullScreen: false)

    XCTAssertEqual(
      writes,
      [
        BooleanAttributeWrite(attribute: fullScreenAttribute, value: true),
        BooleanAttributeWrite(attribute: fullScreenAttribute, value: false),
      ])
  }

  func testToggleFullScreenInvertsOnlyCapturedWindowWhenFocusChanges() throws {
    let fixture = FocusedWindowAXFixture()
    let original = fixture.windowElement
    let next = AXUIElementCreateApplication(getpid() + 2)
    let focusedAppAttribute = AXWindowAttribute.focusedApplication.accessibilityName
    let focusedWindowAttribute = AXWindowAttribute.focusedWindow.accessibilityName
    let fullScreenAttribute = AXWindowAttribute.fullScreen.accessibilityName

    for initial in [false, true] {
      var focusedWindow = original
      var reads: [String] = []
      var writes: [Bool] = []
      let client = AXClient.testing(
        copyAttributeValue: { element, attribute, value in
          let name = attribute as String
          reads.append(name)
          switch name {
          case focusedAppAttribute where CFEqual(element, fixture.systemWideElement):
            value.pointee = fixture.appElement
          case focusedWindowAttribute where CFEqual(element, fixture.appElement):
            value.pointee = focusedWindow
          case fullScreenAttribute where CFEqual(element, original):
            value.pointee = initial ? kCFBooleanTrue : kCFBooleanFalse
            focusedWindow = next
          default:
            XCTFail("Unexpected Accessibility read: " + name)
            return .attributeUnsupported
          }
          return .success
        },
        setAttributeValue: { element, attribute, value in
          XCTAssertTrue(CFEqual(element, original))
          XCTAssertFalse(CFEqual(element, focusedWindow))
          XCTAssertEqual(attribute as String, fullScreenAttribute)
          guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            XCTFail("Expected a native Boolean write")
            return .illegalArgument
          }
          writes.append(boolean)
          return .success
        },
        performAction: { _, _ in
          XCTFail("Toggling must not invoke another Accessibility action")
          return .actionUnsupported
        })

      try fixture.commandController(accessibilityClient: client).toggleFullScreen(.focused)

      XCTAssertTrue(CFEqual(focusedWindow, next))
      XCTAssertEqual(reads, [focusedAppAttribute, focusedWindowAttribute, fullScreenAttribute])
      XCTAssertEqual(writes, [!initial])
    }
  }

  func testToggleFullScreenDoesNotWriteWhenStateIsUnavailableOrInvalid() {
    let fixture = FocusedWindowAXFixture()
    let cases: [(AXError, CFTypeRef?, WindowAccessibilityError)] = [
      (.attributeUnsupported, nil, .unsupportedAccessibilityOperation(.setFullScreen)),
      (.noValue, nil, .unsupportedAccessibilityOperation(.setFullScreen)),
      (.success, nil, .unsupportedAccessibilityOperation(.setFullScreen)),
      (.success, NSNumber(value: 1), .invalidAccessibilityValue(.setFullScreen)),
      (
        .cannotComplete, nil,
        .accessibilityOperationFailed(
          operation: .setFullScreen, failure: .cannotComplete)
      ),
    ]
    for (status, returnedValue, expected) in cases {
      var reads = 0
      let client = fixture.accessibilityClient(
        additionalHandler: { element, attribute, value in
          XCTAssertTrue(CFEqual(element, fixture.windowElement))
          XCTAssertEqual(attribute as String, AXWindowAttribute.fullScreen.accessibilityName)
          reads += 1
          value.pointee = returnedValue
          return status
        },
        setAttributeValue: { _, _, _ in
          XCTFail("Missing, invalid or failed state must not trigger a write")
          return .failure
        },
        performAction: { _, _ in
          XCTFail("An unreadable state must not trigger another action")
          return .actionUnsupported
        })
      let controller = fixture.commandController(accessibilityClient: client)
      XCTAssertThrowsError(try controller.toggleFullScreen(.focused)) { error in
        XCTAssertEqual(error as? WindowAccessibilityError, expected)
      }
      XCTAssertEqual(reads, 1)
    }
  }

  func testToggleFullScreenPropagatesWriteFailureWithoutRetry() {
    let fixture = FocusedWindowAXFixture()
    var writes = 0
    let client = fixture.accessibilityClient(
      additionalHandler: { element, attribute, value in
        XCTAssertTrue(CFEqual(element, fixture.windowElement))
        XCTAssertEqual(attribute as String, AXWindowAttribute.fullScreen.accessibilityName)
        value.pointee = kCFBooleanFalse
        return .success
      },
      setAttributeValue: { element, attribute, value in
        XCTAssertTrue(CFEqual(element, fixture.windowElement))
        XCTAssertEqual(attribute as String, AXWindowAttribute.fullScreen.accessibilityName)
        XCTAssertEqual(value as? Bool, true)
        writes += 1
        return .invalidUIElement
      },
      performAction: { _, _ in
        XCTFail("A failed write must not trigger another action")
        return .actionUnsupported
      })
    let controller = fixture.commandController(accessibilityClient: client)
    XCTAssertThrowsError(try controller.toggleFullScreen(.focused)) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .accessibilityOperationFailed(operation: .setFullScreen, failure: .invalidUIElement))
    }
    XCTAssertEqual(writes, 1)
  }

  func testSetMinimizedThrowsUnderlyingAccessibilityErrorWhenWriteFails() {
    let fixture = FocusedWindowAXFixture()
    let accessibilityClient = fixture.accessibilityClient(setAttributeValue: {
      element, attribute, _ in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      XCTAssertEqual(attribute as String, AXWindowAttribute.minimized.accessibilityName)
      return .cannotComplete
    })

    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    XCTAssertThrowsError(try controller.setMinimized(.focused, isMinimized: true)) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .accessibilityOperationFailed(operation: .setMinimized, failure: .cannotComplete)
      )
    }
  }

  func testRaisePerformsRaiseAction() throws {
    let fixture = FocusedWindowAXFixture()

    var performedActions: [String] = []
    let accessibilityClient = fixture.accessibilityClient(performAction: { element, action in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      performedActions.append(action as String)
      return .success
    })
    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    try controller.raise(.focused)
    XCTAssertEqual(performedActions, [AXWindowAction.raise.accessibilityName])
  }

  func testRaiseThrowsUnderlyingAccessibilityErrorWhenActionFails() {
    let fixture = FocusedWindowAXFixture()

    let accessibilityClient = fixture.accessibilityClient(performAction: { element, action in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      XCTAssertEqual(action as String, AXWindowAction.raise.accessibilityName)
      return .cannotComplete
    })
    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    XCTAssertThrowsError(try controller.raise(.focused)) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .accessibilityOperationFailed(operation: .raise, failure: .cannotComplete)
      )
    }
  }

  func testLowerPerformsLowerAction() throws {
    let fixture = FocusedWindowAXFixture()

    var performedActions: [String] = []
    let accessibilityClient = fixture.accessibilityClient(performAction: { element, action in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      performedActions.append(action as String)
      return .success
    })
    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    try controller.lower(.focused)
    XCTAssertEqual(performedActions, [AXWindowAction.lower.accessibilityName])
  }

  func testLowerThrowsUnsupportedActionWhenLowerActionIsUnsupported() {
    let fixture = FocusedWindowAXFixture()

    let accessibilityClient = fixture.accessibilityClient(performAction: { element, action in
      XCTAssertEqual(CFEqual(element, fixture.windowElement), true)
      XCTAssertEqual(action as String, AXWindowAction.lower.accessibilityName)
      return .actionUnsupported
    })
    let controller = fixture.commandController(accessibilityClient: accessibilityClient)

    XCTAssertThrowsError(try controller.lower(.focused)) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .unsupportedAccessibilityOperation(.lower)
      )
    }
  }
}

private struct BooleanAttributeWrite: Equatable {
  let attribute: String
  let value: Bool
}
