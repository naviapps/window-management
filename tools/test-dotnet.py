#!/usr/bin/env python3
"""Use pinned tooling with this SDK's existing fixture and native layout."""

from _tooling import load, verify_candidate
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
    verify_candidate()


if __name__ == "__main__":
    main()
