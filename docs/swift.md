<a name="swift-window-values-geometry-and-requests"></a>

# Window geometry, filters and requests

Swift and .NET project the same Rust geometry, snapshot filtering and request
contracts. For platform control, see the [native macOS guide](swift-macos.md)
and [Windows behavior](../README.md#windows-behavior).

## Overview

Use `WindowSnapshot` and `WindowSnapshotFilter` for window metadata and filtering.
In Swift, `WindowSnapshotProviding`, `WindowSnapshotResolving`, and
`WindowHitTesting` define the provider boundaries. `WindowTarget` identifies
a window for a control provider.

Swift exposes placement through `WindowPlacementCalculator`, with
`DisplaySelector` and `DisplayMovement` for display targeting and moves.
.NET exposes these calculations through `Geometry`. Complete operations use
`WindowPlacementRequest` and `WindowMoveRequest`.

Snapshot filters compile their immutable include/exclude sets in Rust. A value copy
retains the native selector, and concurrent queries never mutate it. Numeric conditions
reject windows before an adapter requests application metadata. Point containment
uses the same Rust geometry, with minimum edges included and maximum edges excluded.
Numeric filter sets use `Int64` process identifiers and `UInt64` window identifiers.
Swift callers passing native `pid_t` or `CGWindowID` values to filter initializers
convert them with `Int64(process)` or `UInt64(window)` when forming the sets.
Use `WindowSnapshotFilter.init(jsonData:)` for strict original-byte JSON, shared
defaults and strict field checks. .NET accepts the corresponding input through
`WindowSnapshotFilter.FromJsonUtf8`. Application IDs are opaque and Rust matches their
exact scalar spelling. Swift property sets use Swift's canonical string equality;
`WindowSnapshotFilter.jsonData` and Codable preserve all distinct spellings from JSON.
Invalid UTF-8 and malformed .NET UTF-16 identifiers are rejected.
Both Swift properties and canonical JSON use
`includedOwnerApplicationIdentifiers` and `excludedOwnerApplicationIdentifiers`.
Hosts must rename saved `includedOwnerBundleIdentifiers` / `excludedOwnerBundleIdentifiers`
keys before decoding, preserving their opaque identifier arrays and any unresolved input.
Legacy keys are rejected without aliases; native identifiers belong to their OS.

## Geometry and display selection

Use one coordinate space for all bounds, frames and points in a calculation.
`DisplayTarget.containingWindow` selects the display with the greatest positive
intersection with the normalized window frame. Equal areas prefer center containment,
then stable display order; zero-width or zero-height windows use center containment.
This shared rule also determines the source for adjacent-display moves, including
windows whose centers lie in gaps between displays. Selection uses full display
bounds, while placement and movement can use visible bounds for the resulting frame.
Adjacent-display movement keeps the normalized frame when the window is already on
the only display. A removed display identifier or a window outside all displays follows the
selected fallback. Swift `DisplaySelector` / .NET `Geometry.SelectDisplay` default to
first-display fallback, as does the native macOS `WindowPlacer`. Both request
resolvers default to no fallback. Both selectors use the raw point and ordered
index for direct selection. Request construction normalizes nonfinite point
coordinates and negative ordered indexes to zero. Empty display lists never
resolve. Geometry resolution does not query, select or restore a native window.
Swift `DisplaySelector.index(containing:in:)` and .NET `Geometry.IndexContainingPoint`
return the position in deterministic display order, including when input arrives unsorted.
Display order compares normalized x, y, width, and height, treating signed zeros as the
same position. Equal frames sort by ascending identifier, with missing identifiers last.
Equal sort keys retain input order.
Swift and .NET `Display` values use Rust's finite, standardized full and visible frames
when constructed or restored from saved display metadata. .NET record updates apply
the same rule and require the matching native runtime.
Containment and overlap use exact binary coordinates after normalization, and center
ties use the exact midpoint even when it cannot be represented by a floating-point
value. Frame normalization and placement output retain their floating-point calculations.
An inset at or beyond half the shortest dimension collapses that dimension at its rounded
midpoint and reduces the other dimension by the shortest dimension.
Grid offsets and extents are fractions of the inset display area. A full span preserves
the area on that axis, including its smallest representable positive extent.

Create snapshots in tests or host-owned providers without retaining live system objects:

```swift
import CoreGraphics
import WindowManagement

let snapshot = WindowSnapshot(
  ownerProcessIdentifier: 42,
  windowIdentifier: 1001,
  ownerName: "Editor",
  ownerBundleIdentifier: "com.example.editor",
  title: "Document",
  frame: CGRect(x: 120, y: 80, width: 900, height: 640)
)
```

Swift and .NET snapshots normalize saved and newly assigned frames with Rust. The .NET
snapshot uses the matching native runtime for that projection. Swift `WindowSnapshot.contains`
and .NET `WindowSnapshot.Contains` test the normalized frame and exclude maximum edges.
The macOS hit tester and .NET `WindowsDesktop.HitTest` use those bounds and the
shared snapshot filter while keeping each desktop's native front-to-back order.
They report a captured snapshot, an unavailable source, or no matching window.

## Requests and JSON

`WindowPlacementRequest` and `WindowMoveRequest` share Rust validation and normalization
with .NET `FromJson` / `ToJson`, `Geometry.ResolvePlacement` and `ResolveMovement`.
Native placers accept those same requests. Normalize direct Rust values before
serialization; executable geometry always clamps them.

`WindowRequestCodec` and .NET placement and movement `FromJsonUtf8` methods send original
bytes to Rust before a language decoder can consume duplicate keys. Rust writes both languages'
normalized request JSON and rejects duplicates, unknown fields and explicit nulls. Omitted display,
area and inset default to containing-window, visible area and zero. The stored placement
request key remains `screen`, projected by Swift/Rust `display` and .NET `Display`.
JSON round trips preserve finite point coordinates exactly, including signed zero.
Generic nested Codable cannot recover duplicate keys already consumed by its outer decoder.

## Responsibility Boundary

WindowManagement owns window snapshots, query filters, hit-testing protocols and models, placement
geometry, display-selection primitives, and control/provider protocols.
Action SDKs consume these request types directly rather than maintaining parallel window enums.

WindowManagement does not request permissions, install event monitors, persist rules,
run shortcuts, own user interface, collect analytics, transmit data, or store
window history. Those responsibilities stay in the host app.
