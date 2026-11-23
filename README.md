# WindowManagement

Rust-backed window geometry, display selection and native window management.
Swift/AppKit and .NET adapters share the same deterministic core. Hosts own permission
onboarding, product policy, persistence and UI.

## Documentation

- [Platform contracts](#platform-contracts): shared boundaries and Windows behavior.
- [Swift values and providers](https://github.com/naviapps/window-management/blob/main/Sources/WindowManagement/WindowManagement.docc/WindowManagement.md): `WindowManagement` API catalog.
- [Native macOS adapters](https://github.com/naviapps/window-management/blob/main/Sources/WindowManagementMacOS/WindowManagementMacOS.docc/WindowManagementMacOS.md): queries, hit testing, placement and Accessibility.
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

The native ABI is 5. Keep headers and native libraries from the same SDK build.

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
toolchain. Windows packages use `win-x64`. On Windows 11 ARM64, run the installed
package in an x64 .NET process under emulation.

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
[core API catalog](https://github.com/naviapps/window-management/blob/main/Sources/WindowManagement/WindowManagement.docc/WindowManagement.md).
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
[native API catalog](https://github.com/naviapps/window-management/blob/main/Sources/WindowManagementMacOS/WindowManagementMacOS.docc/WindowManagementMacOS.md).

## Repository layout

`crates/` owns Rust, Windows resources and the C ABI; `Sources/` / `Tests/` own Swift
and DocC. Managed projects live in `bindings/dotnet`, independent clients in `fixtures`,
and retained frameworks/notices in `Artifacts` / `ThirdParty`. `tools/` supplies SDK
policy through pinned shared mechanisms.

## Development

### Setup and checks

Run commands from the SDK root. Swift development requires Swift 6.3 or later
on macOS 26 or later. Review `mise.toml`, `rust-toolchain.toml` and `tools/tooling-sources.json`
before installing their pinned Python 3.15.1, Rust 1.99.1, .NET 10 and static tools:

```sh
mise trust mise.toml
mise install
mise exec -- cargo fetch --locked
mise exec -- make check
```

The fetch prepares the producer cache for locked offline Rust checks. Developer entry
points use the immutable `sdk-tooling` pin; see its [setup](https://github.com/naviapps/sdk-tooling#readme)
for verified caches and offline/source overrides. Shared guides
own [quality tools](https://github.com/naviapps/sdk-tooling/blob/main/docs/REFERENCE.md#quality-and-documentation-checks),
[native receipt mechanisms](https://github.com/naviapps/sdk-tooling/blob/main/docs/REFERENCE.md#native-artifacts-and-provenance)
and [consumer isolation](https://github.com/naviapps/sdk-tooling/blob/main/docs/REFERENCE.md#consumer-verification).
Ordinary SwiftPM/C/NuGet consumers do not need developer setup.

Use `mise exec -- make <target>` so pinned tools remain available in temporary clients.

| Target                     | SDK coverage                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| `check`                    | Lint, framework verification, strict Swift tests and release build, Swift consumer, Rust and DocC |
| `test-rust`                | Clippy and workspace tests with `--locked --offline`                                              |
| `test-docs`                | Both catalogs against public symbol graphs, warnings as errors                                    |
| `test-consumer`            | Both Swift products installed with synthetic providers                                            |
| `test-installed-consumers` | Independent Rust Git client and installed-framework C client                                      |
| `test-c` / `test-dotnet`   | Native C / managed boundary fixtures against the framework                                        |
| `native` / `native-verify` | Rebuild / verify the universal macOS framework and receipt                                        |

`mise run lint` checks owned source; `mise run format` formats it. `DOTNET_BIN` selects
an existing .NET executable. Native acceptance is separate from compilation and tests.
The Rust integration suite covers geometry, display selection and the JSON contracts
for placement and movement requests.
Language and installed-consumer fixtures also check coordinate marshalling, typed
results, raw-byte and Codable projection, native ownership and the public entry points.

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
`mise exec -- python3 -B tools/install-consumers.py --git-source <path>`; retain results
with an unused `--evidence` path outside the checkout. This does not test remote
credentials, Windows DLLs or a framework rebuild.

`Artifacts/CWindowManagement.xcframework` and `Artifacts/native-build.json` are retained
consumer inputs. Run `mise exec -- make native` after captured production inputs change,
then `mise exec -- make native-verify`. Test-only Rust edits do not invalidate them.
The framework combines original notices in `Resources/ThirdPartyNotices.txt`; originals
and Rust provenance remain in `ThirdParty/` and accompany selected NuGet runtimes.

Build native assets on their own OS before packing. Windows DLLs and receipts belong
in `.native-build/windows/win-x64`; the macOS framework belongs in `Artifacts`. Pack
and test a local package on macOS:

```sh
mise exec -- python3 -B tools/pack-dotnet.py --runtime osx-arm64 --runtime osx-x64
mise exec -- python3 -B tools/test-package.py .native-build/packages/NaviApps.WindowManagement.0.1.0.nupkg
```

The SDK owns `bindings/dotnet/tests/PackageConsumer/Program.cs`; the shared driver owns
provenance/byte checks and isolated restore. `--package-source <directory>` selects a
private/local feed; `test-package.py --dependency <nupkg>` adds dependencies to its empty
feed. No feed is published. Cross-OS packing checks provenance, while Mach-O/signature
inspection must happen on macOS. Loading a macOS package does not verify Windows.
DesktopActions resolves its WindowManagement dependency by its pinned commit. Use the
tooling revision that produced the selected native receipts when packing. A combined
package requires one tooling revision that verifies every selected receipt.

### Owned platform acceptance

GitHub Actions runs strict Swift tests against the tracked framework on macOS 26
with Xcode 26.6. The Xcode 27 job also verifies Rust, Swift, C and .NET consumers.
In an owned ephemeral VM, `OwnedWindowListRuntimeTests` covers fixture-owned windows,
ordering, transparent-front-window hits and reads after closure. With
`WINDOW_MANAGEMENT_RUN_OWNED_CG_TESTS=1`, `NAVI_CI_OWNED_VM=1` and controller source
commit/fingerprint variables retained, run
`mise exec -- swift test --filter OwnedWindowListRuntimeTests`. The fixture records
whether WindowServer lists the transparent window and changes no permissions/settings.

On an owned Windows 11 ARM64 worker, use native ARM64 Python, Rust and MSVC, the
`x86_64-pc-windows-msvc` Rust standard library and the x64 .NET SDK pinned in `mise.toml`.
Set `DOTNET_BIN` to the absolute x64 executable. Select a locally prepared SDK Tooling
checkout at its exact reviewed commit for the ARM64-hosted build and fixtures:

```powershell
python -B tools/check-windows.py --desktop --tooling-source $tooling --tooling-revision $commit
python -B tools/pack-dotnet.py --runtime win-x64 --tooling-source $tooling --tooling-revision $commit
python -B tools/test-package.py .native-build/packages/NaviApps.WindowManagement.0.1.0.nupkg --tooling-source $tooling --tooling-revision $commit
```

The Windows x64 gate checks PE architecture, exports, CRT linkage, Rust and C fixtures,
managed contracts, and an installed NuGet client. `--desktop` uses the managed API
to control and close a separate owned x64 Win32 window compiled from Rust and
records the host and managed process architecture.
`--build-only` prepares the x64 DLL and receipt without running the fixtures.

The GitHub-hosted Windows x64 workflow runs Rust, tooling, C, .NET and NuGet
package checks. Run the separate `--desktop` fixture on an owned Windows desktop.

The [selection benchmark](https://github.com/naviapps/window-management/blob/main/crates/core/examples/selection_benchmark.rs) runs with
`mise exec -- cargo run -p window-management --example selection_benchmark --release --locked --offline`.
It measures Rust selection across ten displays/ten spanning positions, excluding FFI
and OS calls. Record source, machine, toolchain and timings per result.

## License

This SDK is licensed under the [MIT License](LICENSE). Keep the
[third-party notices](ThirdParty/) with redistributed artifacts.
