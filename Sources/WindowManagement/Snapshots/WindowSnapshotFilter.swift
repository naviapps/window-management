import CWindowManagement
import CoreGraphics
import Foundation

package enum WindowSnapshotIdentityMatch: UInt32 {
  case excluded = 0
  case included = 1
  case requiresApplicationIdentifier = 3
}

/// Rust-owned include/exclude selection shared by snapshot query adapters.
public struct WindowSnapshotFilter: Hashable, Sendable, Codable {
  private struct Values: Sendable, Codable {
    let includedOwnerApplicationIdentifiers: Set<String>
    let includedOwnerProcessIdentifiers: Set<Int64>
    let includedWindowIdentifiers: Set<UInt64>
    let excludedOwnerApplicationIdentifiers: Set<String>
    let excludedOwnerProcessIdentifiers: Set<Int64>
    let excludedWindowIdentifiers: Set<UInt64>
  }
  private let values: Values
  private let compiled: CompiledWindowFilter
  /// Canonical filter JSON. This preserves the exact scalar spelling of every opaque identifier.
  public let jsonData: Data

  /// Included opaque owner application IDs; empty means all owners.
  public var includedOwnerApplicationIdentifiers: Set<String> {
    values.includedOwnerApplicationIdentifiers
  }
  /// Included owner process IDs; empty means all processes.
  public var includedOwnerProcessIdentifiers: Set<Int64> { values.includedOwnerProcessIdentifiers }
  /// Included native window IDs; empty means all windows.
  public var includedWindowIdentifiers: Set<UInt64> { values.includedWindowIdentifiers }
  /// Excluded opaque application IDs. Exclusion wins over inclusion.
  public var excludedOwnerApplicationIdentifiers: Set<String> {
    values.excludedOwnerApplicationIdentifiers
  }
  /// Excluded process IDs. Exclusion wins over inclusion.
  public var excludedOwnerProcessIdentifiers: Set<Int64> { values.excludedOwnerProcessIdentifiers }
  /// Excluded window IDs. Exclusion wins over inclusion.
  public var excludedWindowIdentifiers: Set<UInt64> { values.excludedWindowIdentifiers }

  /// Evaluate identity conditions before resolving optional application metadata.
  package func matchIdentity(
    windowIdentifier: CGWindowID, ownerProcessIdentifier: pid_t
  ) -> WindowSnapshotIdentityMatch {
    compiled.matchIdentity(window: UInt64(windowIdentifier), process: Int64(ownerProcessIdentifier))
  }

  /// Creates an immutable filter. Native IDs belong to the current platform.
  /// Convert native window and process identifiers to `UInt64` and `Int64` for these sets.
  /// Use `init(jsonData:)` for application IDs that Swift's string sets would equate.
  public init(
    includedOwnerApplicationIdentifiers: Set<String> = [],
    includedOwnerProcessIdentifiers: Set<Int64> = [],
    includedWindowIdentifiers: Set<UInt64> = [],
    excludedOwnerApplicationIdentifiers: Set<String> = [],
    excludedOwnerProcessIdentifiers: Set<Int64> = [],
    excludedWindowIdentifiers: Set<UInt64> = []
  ) {
    let values = Values(
      includedOwnerApplicationIdentifiers: includedOwnerApplicationIdentifiers,
      includedOwnerProcessIdentifiers: includedOwnerProcessIdentifiers,
      includedWindowIdentifiers: includedWindowIdentifiers,
      excludedOwnerApplicationIdentifiers: excludedOwnerApplicationIdentifiers,
      excludedOwnerProcessIdentifiers: excludedOwnerProcessIdentifiers,
      excludedWindowIdentifiers: excludedWindowIdentifiers)
    do { try self.init(jsonData: JSONEncoder().encode(values)) } catch {
      preconditionFailure("Invalid native snapshot filter projection: \(error)")
    }
  }

  /// Decode original JSON through Rust, including defaults and duplicate-key checks.
  public init(jsonData: Data) throws {
    let normalized = try WindowJSON.normalize(jsonData, kind: 4)
    values = try JSONDecoder().decode(Values.self, from: normalized)
    compiled = try CompiledWindowFilter(normalized)
    self.jsonData = normalized
  }

  /// Decodes with Rust defaults and validation. Use `init(jsonData:)` to detect duplicate JSON keys.
  public init(from decoder: any Decoder) throws {
    self = try WindowJSON.project(from: decoder) { try Self(jsonData: $0) }
  }

  public func encode(to encoder: any Encoder) throws {
    try WindowJSON.write(jsonData, to: encoder)
  }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.jsonData == rhs.jsonData }
  public func hash(into hasher: inout Hasher) { hasher.combine(jsonData) }

  /// All nonempty include sets must match; any exclusion rejects the snapshot.
  /// Missing application IDs cannot satisfy an application include set.
  public func includes(_ snapshot: WindowSnapshot) -> Bool {
    includes(
      windowIdentifier: snapshot.windowIdentifier,
      ownerProcessIdentifier: snapshot.ownerProcessIdentifier,
      ownerApplicationIdentifier: snapshot.ownerBundleIdentifier)
  }

  /// Applies the shared selector before constructing or enriching a snapshot.
  package func includes(
    windowIdentifier: CGWindowID, ownerProcessIdentifier: pid_t,
    ownerApplicationIdentifier: String?
  ) -> Bool {
    compiled.includes(
      window: UInt64(windowIdentifier),
      process: Int64(ownerProcessIdentifier), application: ownerApplicationIdentifier)
  }
}

/// Immutable native data; ARC owns destruction and all queries borrow self through the C call.
private final class CompiledWindowFilter: @unchecked Sendable {
  private let owner: OpaquePointer
  init(_ data: Data) throws {
    precondition(
      window_management_abi_version() == WINDOW_MANAGEMENT_ABI_VERSION,
      "Unsupported native window ABI")
    guard
      let owner = data.withUnsafeBytes({
        window_management_window_filter_create($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
      })
    else { throw WindowRequestCodecError.invalidData("Cannot create a native snapshot filter") }
    self.owner = owner
  }
  deinit { window_management_window_filter_destroy(owner) }
  func matchIdentity(window: UInt64, process: Int64) -> WindowSnapshotIdentityMatch {
    withExtendedLifetime(self) {
      let result = window_management_window_filter_match_identity(owner, window, process)
      guard let match = WindowSnapshotIdentityMatch(rawValue: result) else {
        preconditionFailure("Invalid native snapshot identity response")
      }
      return match
    }
  }
  func includes(window: UInt64, process: Int64, application: String?) -> Bool {
    withExtendedLifetime(self) {
      let result: UInt32
      if let application {
        result = application.utf8CString.withUnsafeBufferPointer {
          window_management_window_filter_includes(
            owner, window, process,
            UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), $0.count - 1)
        }
      } else {
        result = window_management_window_filter_includes(owner, window, process, nil, 0)
      }
      precondition(result <= 1, "Invalid native snapshot filter response")
      return result == 1
    }
  }
}
