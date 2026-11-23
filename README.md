# WindowManagement

Rust-backed window geometry, display selection and native window management.
Swift/AppKit and .NET adapters share the same deterministic core. Hosts own permission
onboarding, product policy, persistence and UI.

## Documentation

- [Platform contracts](#platform-contracts): shared boundaries and Windows behavior.
- [Swift window values, geometry and requests](https://github.com/naviapps/window-management/blob/main/docs/swift.md)
- [Native macOS queries, hit testing, placement and Accessibility](https://github.com/naviapps/window-management/blob/main/docs/swift-macos.md)
- [Development](#development): setup, checks, native artifacts, packages and owned fixtures.

## Installation

### Swift

Add `https://github.com/naviapps/window-management.git` to a Swift package and pin
its full commit ID. Select `WindowManagement` for values/codecs or
`WindowManagementMacOS` for native macOS control. The tracked XCFramework needs no
Rust build on the consumer's machine.

For example, a Swift 6.3 client on macOS 26 can use this complete manifest. Replace
`FULL_40_CHARACTER_PUBLISHED_COMMIT_ID` with the chosen published SDK revision:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "WindowClient",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(
      url: "https://github.com/naviapps/window-management.git",
      revision: "FULL_40_CHARACTER_PUBLISHED_COMMIT_ID")
  ],
  targets: [
    .executableTarget(
      name: "WindowClient",
      dependencies: [
        .product(name: "WindowManagement", package: "window-management"),
        .product(name: "WindowManagementMacOS", package: "window-management"),
      ])
  ]
)
```

Place client code under `Sources/WindowClient/`. This package has no external
Swift package dependencies; its native runtime and retained notices are tracked.

### Rust

Rust callers select the public geometry and selection crate at a full published
Git revision. Replace the revision placeholder with the chosen 40-character SHA:

```toml
[dependencies]
window-management = { git = "https://github.com/naviapps/window-management.git", rev = "FULL_40_CHARACTER_PUBLISHED_COMMIT_ID" }
```

The client uses its own `Cargo.lock` and the Rust toolchain for its target.
`window-management-windows` is the separate Win32 adapter. The workspace
declares Rust 1.85; the installed consumer gate uses the pinned Rust 1.99.1 and
does not establish build or runtime support at the declared minimum.

### C

The native ABI is 6. Keep headers and native libraries from the same SDK build.

Compile a snapshot filter with `window_management_window_filter_compile`.
The separate JSON result contains the canonical filter or a diagnostic.
Destroy the JSON result after copying its bytes. The compiled filter remains
available for queries until its own destruction.

A macOS C client installs `CWindowManagement.framework` from the universal
macOS 26 slice of `Artifacts/CWindowManagement.xcframework`, preserving its
headers, resources, symlinks and notices. Include
`<CWindowManagement/window_management.h>` and link `-framework CWindowManagement`,
with `-F` and a runtime search path pointing to the installed framework's parent.
Keep the retained third-party notices with the framework. This client needs
neither Rust nor an SDK source include path. The Windows DLL and import library
have their own native acceptance path.

C query views borrow their owner. Bindings copy foreign strings and arrays before
release. Buffers must remain readable/writable for declared sizes; null/count/alignment
checks cannot establish arbitrary pointer validity.

### .NET

.NET 10 consumers use `NaviApps.WindowManagement` from a private/local NuGet feed.
The package carries its selected native runtimes; consumers need no Rust or MSVC
toolchain. To add a package from a local feed in an existing project, replace the
feed path and use the version of the package you received.

```sh
dotnet add package NaviApps.WindowManagement --version 0.1.0 --source /path/to/nuget-feed
```

The package must include the runtime used by your app. On macOS the native
assets are `osx-arm64` or `osx-x64`. Windows packages use `win-x64`. On Windows 11
ARM64, run the installed package in an x64 .NET process under emulation.

Keep the managed package and native runtime assets from the same SDK build. Private
feed publication is separate from CI or local package generation. See the
[package workflow](#consumers-artifacts-and-packages)
when building a local feed.

## Usage

Calculate a frame from synthetic geometry without querying or controlling desktop windows:

```swift
import CoreGraphics
import WindowManagement

let leftHalf = WindowPlacementCalculator.frame(
  for: .grid(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1),
  in: CGRect(x: 0, y: 0, width: 1440, height: 900)
)
```

For live macOS placement, call the native adapter from the main actor after the
host has obtained Accessibility permission:

```swift
import WindowManagement
import WindowManagementMacOS

@MainActor
func placeFocusedWindow() throws {
  try WindowPlacer().place(
    .centered(widthRatio: 0.8, heightRatio: 0.8),
    for: .focused,
    displayFallback: .none
  )
}
```

The .NET geometry API uses the same Rust engine and can run with a matching native
runtime on macOS or Windows:

```csharp
using NaviApps.WindowManagement;

Rect leftHalf = Geometry.Grid(new Rect(0, 0, 1440, 900), 2, 1, 0, 0);
```

Use `WindowsDesktop` for live Windows queries and control. Capture a `WindowIdentity`
before issuing a command. Discovery does not activate windows. State commands retain
native activation behavior.

## Platform contracts

Geometry uses one caller-selected coordinate space. Default macOS placement uses
Accessibility coordinates (primary-display top-left origin, y increasing downward).
Windows uses physical virtual-desktop pixels. Injected providers must agree on
coordinates. Swift `DisplaySelector` and .NET `Geometry.SelectDisplay` default to
first-display fallback. Swift `WindowRequestResolver` and the .NET request resolvers
default to no fallback. Swift `WindowPlacer` defaults to first-display fallback.
Empty display lists never resolve.

Native requests can fail or be constrained by the target application. Close/state
acceptance proves neither completion nor saved data. Shared geometry, snapshot filtering
and strict JSON contracts are documented in the
[core guide](https://github.com/naviapps/window-management/blob/main/docs/swift.md).
Compilation does not establish native runtime coverage; acceptance belongs to its source
and environment.

### Windows behavior

`WindowIdentity` captures HWND, process ID and thread ID. The SDK checks them before
control and around snapshot sampling. A malformed identity returns `InvalidInput`.
A captured window that disappeared or changed owners returns `TargetChanged`. These
checks are best effort because Windows can recycle handles. .NET `SetFrame` returns
the actual, possibly constrained frame and reports typed `WindowOperationException`
failures. Rust state commands accept `WindowState::Normal`, `Minimized` or `Maximized`.
Raw operation codes stay at the C boundary. Discovery does not activate windows. State
commands retain native placement behavior. Maximizing uses the activating `SW_SHOWMAXIMIZED`
state documented by [Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow).
Immediate state readback does not wait for application UI work to finish.

Visible enumeration excludes [DWM-cloaked windows](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute),
including those hidden on other virtual desktops; explicit identity queries can inspect
them. `foreground_window()` / `WindowsDesktop.GetForegroundWindow()` read the foreground
window snapshot without activation or keyboard-focus queries. Use `foreground_window_identity()`
or `WindowsDesktop.GetForegroundWindowIdentity()` to capture only the HWND, process and thread
for later control. This path samples the foreground handle before and after reading ownership
and can report `Unavailable` or `TargetChanged`. It reads no title, frame or state, and leaves
the caller's DPI context unchanged. The former Rust `focused_window()`
spelling is removed. Windows snapshots supply no application identifier. For
application-ID filters, pass an opaque identifier to `filter.Includes(snapshot, identifier)`
or provide an owner resolver to `WindowsDesktop.GetWindows(filter, resolveOwnerApplicationIdentifier)`.
The resolver receives candidates that pass numeric conditions when the filter contains
an application include or exclusion. An unresolved owner cannot satisfy an application
include set. Both query forms retain native z order.

Windows point queries use physical coordinates and sample the pixel at each coordinate's
floor. This follows the [native rectangle convention](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getwindowrect)
of including the top and left edges and excluding the bottom and right edges. Frame
commands round coordinates to the nearest pixel.

`WindowsDesktop.HitTest(x, y, filter)` selects the first visible, non-minimized
top-level window whose bounds contain the point and match the optional filter.
Native enumeration order breaks overlaps. The same application-identifier resolver
overload as `GetWindows` resolves only candidates that pass geometry and numeric
conditions. A failed enumeration returns `SourceUnavailable`; no matching bounds
or an invalid point returns `NoMatchingWindowAtPoint`. These are values in
`WindowHitTestResult.MissReason`. A hit provides the captured `Snapshot`.
`GetWindowAt(x, y)` returns the root of the Win32 input hit at the requested pixel.

Windows close requests post an ordinary close after identity validation. Applications
may prompt, refuse or complete later; there is no process termination, keyboard shortcut
or replacement-window fallback. macOS command details belong to the
[native guide](https://github.com/naviapps/window-management/blob/main/docs/swift-macos.md).

## Repository layout

`crates/` owns Rust, Windows resources and the C ABI; `Sources/` / `Tests/` own Swift
source and tests. Managed projects live in `bindings/dotnet/` and independent clients in
`fixtures/consumers/`. The separate-process Windows desktop fixture lives in
`fixtures/acceptance/windows/`. The [native build policy](native.toml) selects the framework in `Artifacts/`.
Upstream notices are retained in `ThirdParty/`. Package and Windows acceptance drivers are in
`distribution/`.

## Development

### Setup and checks

Run commands from the SDK root. Swift development requires Swift 6.3 or later
on macOS 26 or later. Review `mise.toml` and `rust-toolchain.toml` before installing
their pinned Python 3.15.1, Rust 1.99.1, .NET 10 and static tools:

```sh
mise trust mise.toml
mise install
mise exec -- cargo fetch --locked
mise exec -- make check
```

The fetch prepares the Cargo cache for locked offline Rust checks. Formatting,
Rust and Swift tests run from this checkout. Formatting and the standalone Swift
consumer use the public SDK Tooling CLI pinned in [mise.toml](mise.toml). Ordinary
SwiftPM, C and NuGet consumers do not need developer tools.

Use `mise exec -- make <target>` so pinned tools remain available in temporary clients.

| Target                     | SDK coverage                                                                            |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `check`                    | Lint, Rust tests and Clippy, strict Swift tests, Swift consumer and managed compilation |
| `check-distribution`       | Framework, Swift release build, distribution fixtures and installed clients             |
| `test-rust`                | Clippy and workspace tests with `--locked --offline`                                    |
| `test-consumer`            | Both Swift products installed with synthetic providers                                  |
| `test-installed-consumers` | Independent Rust Git client and installed-framework C client                            |
| `test-c` / `test-dotnet`   | Native C / managed boundary fixtures against the framework                              |
| `native` / `native-verify` | Rebuild / verify the universal macOS framework and receipt                              |

`mise run lint` checks owned source; `mise run format` formats it. `DOTNET_BIN` selects
an existing .NET executable. Native acceptance is separate from compilation and tests.
The Rust integration suite covers geometry, display selection and the JSON contracts
for placement and movement requests.
Language and installed-consumer fixtures also check coordinate marshalling, typed
results, raw-byte and Codable projection, native ownership and the public entry points.

### Distribution verification

The [distribution plan](sdk-distribution.toml) selects this SDK's macOS and Windows
x64 checks. From a clean, committed checkout on macOS, run the checks with the
public SDK Tooling CLI pinned in [mise.toml](mise.toml):

```sh
mise exec -- make check-distribution
```

Run the hosted macOS and Windows distribution checks from the SDK checkout at
the intended commit on `main`:

```sh
gh workflow run check-sdk-distribution.yml -R naviapps/sdk-tooling \
  -f sdk=window-management -f "revision=$(git rev-parse HEAD)"
```

### Consumers, artifacts and packages

The Swift fixture installs only the manifest, sources, required test directories,
framework, notices and license. It tests geometry/filtering and `WindowPlacer` through
synthetic providers, including failure before frame access with no displays. It never
queries or controls desktop windows; the installed tree contains no Rust or SDK tooling.

`test-installed-consumers` requires a clean committed checkout, pinned Rust and Xcode on
macOS. The Rust client uses a local Git mirror and fetches registry
dependencies into a fresh cache before locked offline checks; the C client uses the
copied framework/header. Both test synthetic placement and missing-display fallback.
For shallow checkouts, pass a complete repository/bundle with
`mise run sdk-tooling -- rust-c-consumers --git-source <path>`; retain results
with an unused `--evidence` path outside the checkout. This does not test remote
credentials, Windows DLLs or a framework rebuild.

`Artifacts/CWindowManagement.xcframework` and `Artifacts/native-build.json` are retained
consumer inputs. Run `mise exec -- make native` after captured production inputs change,
then `mise exec -- make native-verify`. Test-only Rust edits do not invalidate them.
The [native build policy](native.toml) and its inputs are recorded in the receipt.
The framework combines original notices in `Resources/ThirdPartyNotices.txt`; originals
and Rust provenance remain in `ThirdParty/` and accompany selected NuGet runtimes.

Build native assets on their own OS before packing. Windows DLLs and receipts belong
in `.native-build/windows/win-x64`; the macOS framework belongs in `Artifacts`. Pack
and test a local package on macOS:

```sh
mise run sdk-tooling -- python distribution/pack_nuget.py --runtime osx-arm64 --runtime osx-x64
mise run sdk-tooling -- nuget-consumer .native-build/packages/NaviApps.WindowManagement.0.1.0.nupkg
```

The package fixture in `fixtures/consumers/dotnet/Program.cs` runs after
receipt and byte checks in an isolated restore. JSON reflection is disabled, so
the installed fixture checks that typed snapshot filters and Rust-owned codecs
work without it. `--package-source <directory>` selects a
private/local feed; `nuget-consumer --dependency <nupkg>` adds dependencies to its empty
feed. No feed is published. Cross-OS packing checks provenance, while Mach-O/signature
inspection must happen on macOS. The shared distribution workflow's macOS job
packs its regenerated framework and the accepted Windows DLL as
`osx-arm64`, `osx-x64` and `win-x64` in one NuGet package. Independent macOS
and Windows consumers run the same package bytes. Select `windows-on-arm` when
dispatching to test the x64 package on an additional Windows on Arm runner.
DesktopActions resolves its WindowManagement dependency by its pinned commit.
Each selected runtime's receipt must verify against this checkout before packing.

### Owned platform acceptance

GitHub Actions runs the same strict Swift tests and standalone Swift consumer
against the tracked framework on macOS 26 and 27. The public Windows x64 job
runs Rust and .NET binding tests. SDK Tooling verifies the distribution and
runs the installed Rust, C and .NET consumers in its macOS distribution job.
In an owned ephemeral VM, `OwnedWindowListRuntimeTests` covers fixture-owned windows,
ordering, transparent-front-window hits and reads after closure. With
`WINDOW_MANAGEMENT_RUN_OWNED_CG_TESTS=1`, `VM_RUNNER_OWNED_VM=1` and controller source
commit/fingerprint variables retained, run
`mise exec -- swift test --filter OwnedWindowListRuntimeTests`. The fixture records
whether WindowServer lists the transparent window and changes no permissions/settings.

On an owned Windows 11 worker, use Python, Rust and MSVC matching the worker's
architecture, the `x86_64-pc-windows-msvc` Rust standard library and the x64 .NET SDK
pinned in `global.json`. Set `DOTNET_BIN` to the absolute x64 executable. Windows ARM64
builds x64 artifacts and runs the x64 fixtures through Windows emulation:

```powershell
mise run sdk-tooling -- python distribution/verify_windows_native.py --desktop
mise run sdk-tooling -- python distribution/pack_nuget.py --runtime win-x64
mise run sdk-tooling -- nuget-consumer .native-build/packages/NaviApps.WindowManagement.0.1.0.nupkg
```

The Windows x64 gate checks PE architecture, exports, CRT linkage, Rust and C fixtures,
managed contracts, and an installed NuGet client. `--desktop` uses the managed API
to control and close a separate owned x64 Win32 window compiled from Rust and
records the host and managed process architecture.
`--build-only` prepares the x64 DLL and receipt without running the fixtures.

The SDK Tooling Windows x64 distribution job runs the full DLL and NuGet
package checks. Run the `--desktop` fixture on an owned Windows desktop.

The [selection benchmark](https://github.com/naviapps/window-management/blob/main/crates/core/examples/selection_benchmark.rs) runs with
`mise exec -- cargo run -p window-management --example selection_benchmark --release --locked --offline`.
It measures Rust selection across ten displays/ten spanning positions, excluding FFI
and OS calls. Record source, machine, toolchain and timings per result.

## License

This SDK is licensed under the [MIT License](LICENSE). Keep the
[third-party notices](ThirdParty/) with redistributed artifacts.
