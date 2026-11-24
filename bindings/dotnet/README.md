# NaviApps.WindowManagement

Calculate window frames, select displays and filter snapshots with the shared
Rust core. The package targets .NET 10 and includes native assets for macOS 26
or later on ARM64 and x64, and Windows x64. On Windows 11 ARM64, use x64 .NET
under emulation.

## Install

Download the combined NuGet package and its receipt from the successful
[distribution run](https://github.com/naviapps/sdk-tooling/actions/workflows/check-sdk-distribution.yml)
for your SDK revision. Verify the package's SHA-256 against the receipt. In a new
directory, use the version in the downloaded filename and the absolute path to
the local feed.

```sh
dotnet new console --framework net10.0 --no-restore
dotnet package add NaviApps.WindowManagement --version "[0.1.0]" --no-restore
dotnet restore --source "/absolute/path/to/sdk-packages" --packages ./.nuget-packages
```

Choose a fresh cache directory each time you switch between candidate packages
with the same version. Package consumers need only .NET and the supplied native
assets.

## Calculate a frame

Replace `Program.cs` with this example and run `dotnet run --no-restore`.
It prints `720` without querying or controlling desktop windows.

```csharp
using NaviApps.WindowManagement;

var leftHalf = Geometry.Grid(new Rect(0, 0, 1440, 900), 2, 1, 0, 0);
Console.WriteLine(leftHalf.Width);
```

Use `WindowsDesktop` on Windows for live queries and control. Capture a
`WindowIdentity` before issuing a command. See the
[Windows contract](https://github.com/naviapps/window-management#windows-behavior),
the [shared geometry and JSON guide](https://github.com/naviapps/window-management/blob/main/docs/swift.md)
and the [maintainer packaging instructions](https://github.com/naviapps/window-management#consumers-artifacts-and-packages).
