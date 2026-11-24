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
    parser.add_argument(
        "--result", type=Path, help="Write the accepted package filename to a new file"
    )
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    native = ffi_product(root) if set(args.runtime) == {RID} else xcframework(root)
    nuget = load("nuget")
    selected = {"LICENSE": root / "LICENSE", "README.md": root / "bindings/dotnet/README.md"}
    selected.update(nuget.retained_notice_files(root / "ThirdParty", "ThirdParty"))
    package = nuget.pack_native(
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
    if args.result is not None:
        with args.result.open("x", encoding="utf-8") as output:
            output.write(package.name)


if __name__ == "__main__":
    main()
