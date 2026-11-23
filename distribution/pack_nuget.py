#!/usr/bin/env python3
"""Select this SDK's managed package and retained notices; publish nothing."""

import argparse
from pathlib import Path

from sdk_tooling.adapters import load
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.xcframework import xcframework

from distribution.windows_target import RID


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--runtime", action="append", required=True, choices=("osx-arm64", "osx-x64", RID)
    )
    parser.add_argument("--package-source", action="append", default=[])
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    native = ffi_product(root) if set(args.runtime) == {RID} else xcframework(root)
    selected = {"LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    selected.update(
        {
            "ThirdParty/" + path.relative_to(root / "ThirdParty").as_posix(): path
            for path in load("artifacts").files(root / "ThirdParty")
            if path.name not in (".DS_Store", "registry-notices.json")
        }
    )
    load("nuget").pack_native(
        native,
        project=root
        / "bindings/dotnet/src/NaviApps.WindowManagement/NaviApps.WindowManagement.csproj",
        package_files=selected,
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        input_files=[
            Path(__file__),
            root / "native.toml",
            root / "mise.toml",
        ],
        runtimes=args.runtime,
        sources=args.package_source,
    )


if __name__ == "__main__":
    main()
