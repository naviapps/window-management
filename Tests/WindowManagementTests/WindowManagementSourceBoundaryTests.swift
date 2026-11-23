import Foundation
import XCTest

final class WindowManagementSourceBoundaryTests: XCTestCase {
  func testLiveWindowQueryingStaysOutOfCoreWindowManagementSources() throws {
    let sourceText = try SourceBoundarySupport.sourceFilesText(
      relativeRoot: "Sources/WindowManagement")
    for platformImport in ["AppKit", "ApplicationServices", "Cocoa"] {
      XCTAssertFalse(
        sourceText.containsImport(platformImport),
        "\(platformImport) belongs to WindowManagementMacOS or host code, not the platform-neutral WindowManagement core."
      )
    }
    XCTAssertFalse(
      sourceText.contains("CGWindowList"),
      "Live window querying belongs to WindowManagementMacOS or host code, not the platform-neutral WindowManagement core."
    )
  }

  func testRunningApplicationAdaptersDoNotImportCoreWindowManagement() throws {
    let sourceText = try SourceBoundarySupport.sourceFilesText(
      relativeRoot: "Sources/WindowManagementMacOS/RunningApplications"
    )

    XCTAssertFalse(
      sourceText.containsImport("WindowManagement"),
      "Running application adapters should stay at the AppKit/Darwin process boundary and avoid importing core WindowManagement types they do not use."
    )
  }

  func testAppKitImplementationSeamsStayOutOfPublicSurface() throws {
    let sourceText = try SourceBoundarySupport.sourceFilesText(
      relativeRoot: "Sources/WindowManagementMacOS"
    )
    let internalTypes = [
      "AXClient",
      "AXWindowAccess",
      "AXWindowAction",
      "AXWindowElementResolver",
      "AXWindowError",
      "RunningApplicationChecking",
      "NSRunningApplicationChecker",
      "SystemWindowListProvider",
      "WindowListEntry",
      "WindowListProviding",
      "WindowListRequest",
      "WindowListSnapshotMapper",
      "WindowRoleResolver",
    ]

    for internalType in internalTypes {
      XCTAssertFalse(
        containsPublicDeclaration(named: internalType, in: sourceText),
        "\(internalType) is an AppKit implementation detail and should not become public API."
      )
    }
    XCTAssertFalse(
      sourceText.contains("@usableFromInline"),
      "WindowManagementMacOS should not create semi-public inlinable seams."
    )
    XCTAssertFalse(
      sourceText.contains("@_spi"),
      "WindowManagementMacOS should not expose SPI as a compatibility seam."
    )
  }

  private func containsPublicDeclaration(named typeName: String, in source: String) -> Bool {
    let pattern =
      #"^\s*(?:@[\w.]+(?:\([^)]*\))?\s*)*(?:public|open)\s+(?:actor|class|enum|final\s+class|protocol|struct|typealias)\s+"#
      + NSRegularExpression.escapedPattern(for: typeName)
      + #"\b"#

    return source.split(separator: "\n").contains { line in
      line.range(of: pattern, options: .regularExpression) != nil
    }
  }

}

extension String {
  fileprivate func containsImport(_ moduleName: String) -> Bool {
    range(
      of: #"(?m)^\s*import\s+"# + NSRegularExpression.escapedPattern(for: moduleName) + #"\b"#,
      options: .regularExpression
    ) != nil
  }
}
