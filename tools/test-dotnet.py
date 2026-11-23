#!/usr/bin/env python3
"""Run this SDK's managed fixture against its native library."""

from _tooling import load
from _windows import consumer_options
from native import builder


def main(argv=None):
    options = consumer_options(argv)
    native = builder()
    root = native.root
    framework = (
        native.artifact / "macos-arm64_x86_64" / (native.module + ".framework") / native.module
    )

    load("consumers").check_dotnet(
        project=root
        / "bindings/dotnet/tests/NaviApps.WindowManagement.Tests/NaviApps.WindowManagement.Tests.csproj",
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        framework=framework,
        library_name=native.library,
        windows_root=root / ".native-build/windows",
        work_parent=root / ".native-build/managed",
        cwd=root,
        argv=options,
    )


if __name__ == "__main__":
    main()
