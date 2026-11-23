import ApplicationServices
import WindowManagement
import XCTest

@testable import WindowManagementMacOS

final class AXWindowErrorTests: XCTestCase {
  func testAXWindowErrorEquatableDistinguishesCasesAndAssociatedValues() {
    XCTAssertNotEqual(
      AXWindowError.applicationNotFound(.focused),
      .applicationNotFound(.windowIdentifier(1))
    )
    XCTAssertNotEqual(
      AXWindowError.windowNotFound(.focused),
      .windowNotFound(.windowIdentifier(1))
    )
    XCTAssertNotEqual(
      AXWindowError.applicationNotFound(.focused),
      .windowNotFound(.focused)
    )
    XCTAssertNotEqual(
      AXWindowError.underlyingAccessibilityError(.notImplemented),
      .underlyingAccessibilityError(.cannotComplete)
    )
  }

  func testAXWindowErrorMapsToPublicAccessibilityError() {
    XCTAssertEqual(
      AXWindowError.accessibilityNotTrusted.windowAccessibilityError(for: .readFrame),
      .accessibilityNotTrusted
    )
    XCTAssertEqual(
      AXWindowError.applicationNotFound(.focused).windowAccessibilityError(for: .readFrame),
      .applicationUnavailable(.focused)
    )
    XCTAssertEqual(
      AXWindowError.windowNotFound(.windowIdentifier(1)).windowAccessibilityError(for: .readFrame),
      .windowUnavailable(.windowIdentifier(1))
    )
    XCTAssertEqual(
      AXWindowError.invalidAXValue.windowAccessibilityError(for: .readFrame),
      .invalidAccessibilityValue(.readFrame)
    )
    XCTAssertEqual(
      AXWindowError.unsupportedOperation.windowAccessibilityError(for: .raise),
      .unsupportedAccessibilityOperation(.raise)
    )
    XCTAssertEqual(
      AXWindowError.underlyingAccessibilityError(.cannotComplete)
        .windowAccessibilityError(for: .readFrame),
      .accessibilityOperationFailed(operation: .readFrame, failure: .cannotComplete)
    )
  }

  func testEveryKnownAXErrorMapsToStablePublicOperationFailure() {
    let cases: [(AXError, WindowAccessibilityOperationFailure)] = [
      (.success, .unexpectedSuccess),
      (.failure, .failure),
      (.illegalArgument, .illegalArgument),
      (.invalidUIElement, .invalidUIElement),
      (.invalidUIElementObserver, .invalidUIElementObserver),
      (.cannotComplete, .cannotComplete),
      (.attributeUnsupported, .attributeUnsupported),
      (.actionUnsupported, .actionUnsupported),
      (.notificationUnsupported, .notificationUnsupported),
      (.notImplemented, .notImplemented),
      (.notificationAlreadyRegistered, .notificationAlreadyRegistered),
      (.notificationNotRegistered, .notificationNotRegistered),
      (.apiDisabled, .apiDisabled),
      (.noValue, .noValue),
      (.parameterizedAttributeUnsupported, .parameterizedAttributeUnsupported),
      (.notEnoughPrecision, .notEnoughPrecision),
    ]

    for (axError, expectedFailure) in cases {
      XCTAssertEqual(
        AXWindowError.underlyingAccessibilityError(axError)
          .windowAccessibilityError(for: .readFrame),
        .accessibilityOperationFailed(operation: .readFrame, failure: expectedFailure)
      )
    }
  }

  func testUnrecognizedAXErrorMapsToPublicUnrecognizedOperationFailure() throws {
    let unknownAXError = try XCTUnwrap(AXError(rawValue: 9999))

    XCTAssertEqual(
      AXWindowError.underlyingAccessibilityError(unknownAXError)
        .windowAccessibilityError(for: .readFrame),
      .accessibilityOperationFailed(operation: .readFrame, failure: .unrecognizedAXError)
    )
  }

}
