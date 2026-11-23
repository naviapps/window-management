# ``WindowManagementMacOS``

AppKit and Accessibility implementations plus AX-specific window role metadata.

## Overview

Use WindowManagementMacOS when a macOS host app needs live window information or placement through AppKit
and Accessibility-backed facades.

The package provides live Core Graphics, AppKit, and Accessibility-backed facades and concrete
implementations for WindowManagement protocols:

- `WindowSnapshotQuery` for Core Graphics window-list snapshots.
- `WindowHitTester` for Core Graphics window-list hit testing.
- `WindowPlacer` for placing live windows using `WindowPlacement` values.
- Accessibility-backed `AXWindowController` for frame, state, command, and role protocols.
- `WindowRole` and `WindowRoleProviding` for app-facing role metadata.

Host apps should prefer `WindowManagement` protocols at their own boundaries and construct
`WindowManagementMacOS` concrete adapters where live AppKit or Accessibility access is needed.
`WindowRole` is role metadata for host decisions; it does not define placement rules, presets,
automation policy, or app workflows.

Use the AppKit-backed query and hit tester when a host app needs current window snapshots:

```swift
import WindowManagement
import WindowManagementMacOS

let query = WindowSnapshotQuery()
let snapshots = try query.snapshots()
let hitTester = WindowHitTester()
let topmost = hitTester.topmost(at: .zero)
```

Each operation reads a fresh Core Graphics list. The adapter retains that native
array while it lazily decodes candidates in their original front-to-back order.
Layer, frame, point and numeric-ID checks precede optional owner metadata lookup.
Application-ID constraints resolve the owner identifier before the Rust predicate;
accepted snapshots then retain the available owner/name/title metadata. Topmost
selection stops at the first match, and a known-ID query skips unrelated rows
before enrichment. The adapter does not cache window or process metadata across
calls. Laziness reduces decoding and enrichment work; it does not reduce the
one Core Graphics list call or retain less than the returned native array.

Hit testing and snapshot queries consider normal-level windows by default. To
include a floating palette when choosing the window at a point, pass the exact
Core Graphics levels to the hit tester:

```swift
import CoreGraphics
import WindowManagementMacOS

let hitTester = WindowHitTester(
  windowLevels: [CGWindowLevelForKey(.normalWindow), CGWindowLevelForKey(.floatingWindow)]
)
```

This setting affects only the hit tester. The levels allow candidates into the
same front-to-back traversal; they do not rank candidates or expand snapshot
queries. Hit testing skips windows with a reported overall alpha of zero. A
partly transparent window or one without a reported alpha still uses its bounds.
The hit tester cannot tell whether a window ignores mouse events or has a
transparent area at the point, so an overlay on an included level may be selected.
Snapshot queries do not filter by alpha.

The default `WindowPlacer()` converts AppKit display geometry to Accessibility coordinates, whose
origin is the primary display's top-left corner. Y increases downward, so grid row zero is the top
row and displays above the primary display have negative y coordinates. `AXWindowController`
and Core Graphics window snapshots use that space. `AppKitDisplayProvider` retains AppKit's bottom-left
origin; caller-supplied frame/display providers and point targets must already agree on coordinates.
The `DisplayTarget.main` target uses the system's primary display (the first screen in the AppKit
snapshot), even when the focused window is on another display.

When `AXWindowController` resolves a known window identifier, it skips elements
invalidated after the application's window list was read. A closed sibling therefore
does not prevent finding the target. If no live element matches, resolution reports
the target as unavailable. Other lookup failures propagate without a retry or a
fallback to the focused window.

For placement based on the containing display and adjacent-display movement, the native
`AXWindowController` captures one Accessibility window for the frame read and writes.
A placement on the containing display or an adjacent-display move that keeps the captured
window size writes only its position, so a movable window with a read-only size can be placed
when the requested size already matches. If the destination requires a different size, the
operation still requests the resize. An adjacent-display move leaves a window already on the
only display unchanged, even if it extends beyond the usable area. A window outside every
display still follows the requested fallback policy. Direct `setFrame` and placements on
explicit displays continue to request both position and size.
A frame change that includes a size write stops before moving the window if Accessibility
reports that its size is read-only. If the query is unavailable, the controller still attempts
the writes. The check is not a guarantee: a window can still refuse a later write.
A focus change does not redirect the operation to another window. If the captured element becomes
unavailable, its write fails without resolving a replacement. Explicit display placements still
avoid reading the current frame. Caller-supplied frame controllers retain their own target
resolution semantics.

``AXWindowController/requestClose(_:)`` resolves one window once, reads its
[close button](https://developer.apple.com/documentation/applicationservices/kaxclosebuttonattribute),
and requests the native press action on that element. Missing close support reports
an unsupported operation. A save prompt, refusal or asynchronous close remains under
the application’s control; request acceptance proves neither closure nor saved data.
No application termination, keyboard shortcut or replacement window is used as a fallback.

``AXWindowController/toggleFullScreen(_:)`` reads the native full-screen Boolean and writes its
inverse on the same Accessibility window, even if focus changes during the read. If the state is
unavailable or invalid, it fails without writing. The request uses the same Accessibility
permission and error classification as ``AXWindowController/setFullScreen(_:isFullScreen:)``.
It never posts a keyboard shortcut, selects another window, or waits for the transition to finish.

## Responsibility Boundary

WindowManagementMacOS owns AppKit-backed querying and hit-testing initializers,
Accessibility-backed live window placement helpers, and role metadata.

Host apps remain responsible for permission onboarding, user-facing prompts,
shortcut handling, automation policy, persistence, telemetry, analytics, and
privacy disclosures.

WindowManagementMacOS does not request permissions, collect analytics, transmit data, or persist window
data by itself. Metadata availability and permission prompts are controlled by macOS and the host
application.

## Topics

### Querying and Hit Testing

- ``WindowSnapshotQuery``
- ``WindowSnapshotQuery/init(ownerBundleIdentifierProvider:filter:limit:)``
- ``WindowSnapshotQuery/snapshots()``
- ``WindowSnapshotQuery/snapshot(for:)``
- ``WindowSnapshotQueryLimit``
- ``WindowSnapshotQueryError``
- ``WindowHitTester``
- ``WindowHitTester/init(pointTransform:filter:)``
- ``WindowHitTester/init(windowLevels:pointTransform:filter:)``
- ``WindowOwnerBundleIdentifierProviding``
- ``WindowOwnerBundleIdentifierProviding/bundleIdentifier(forProcessIdentifier:)``
- ``NSRunningApplicationBundleIdentifierProvider``
- ``NSRunningApplicationBundleIdentifierProvider/init()``
- ``NSRunningApplicationBundleIdentifierProvider/bundleIdentifier(forProcessIdentifier:)``

### Placement

- ``WindowPlacer``
- ``WindowPlacer/init()``
- ``WindowPlacer/init(frameController:displayProvider:)``
- ``WindowPlacer/place(_:for:display:area:inset:displayFallback:)``
- ``WindowPlacer/moveToAdjacentDisplay(_:for:preservingRelativePosition:displayFallback:)``
- ``WindowPlacerError``
- ``AppKitDisplayProvider``
- ``AppKitDisplayProvider/init()``
- ``AppKitDisplayProvider/displays()``

### Accessibility Access

- ``WindowAccessibilityError``
- ``WindowAccessibilityOperation``
- ``WindowAccessibilityOperationFailure``
- ``AXWindowController``
- ``AXWindowController/init()``
- ``AXWindowController/frame(for:)``
- ``AXWindowController/setFrame(_:for:)``
- ``AXWindowController/state(for:)``
- ``AXWindowController/requestClose(_:)``
- ``AXWindowController/setMinimized(_:isMinimized:)``
- ``AXWindowController/setFullScreen(_:isFullScreen:)``
- ``AXWindowController/toggleFullScreen(_:)``
- ``AXWindowController/raise(_:)``
- ``AXWindowController/lower(_:)``
- ``AXWindowController/role(for:)``

### Roles

- ``WindowRole``
- ``WindowRoleProviding``
- ``WindowRoleProviding/role(for:)``
