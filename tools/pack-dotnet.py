#!/usr/bin/env python3
"""Select this SDK's managed package and retained notices; publish nothing."""

import argparse
import tomllib
from pathlib import Path

from _tooling import load, support_inputs
from _windows import RID
from native import builder


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--runtime", action="append", required=True, choices=("osx-arm64", "osx-x64", RID)
    )
    parser.add_argument("--package-source", action="append", default=[])
    args = parser.parse_args(argv)
    native = builder()
    root = native.root
    selected = {"LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    selected.update(
        {
            "ThirdParty/" + path.relative_to(root / "ThirdParty").as_posix(): path
            for path in load("artifacts").files(root / "ThirdParty")
            if path.name not in (".DS_Store", "registry-notices.json")
        }
    )
    load("bindings").pack_native(
        native,
        project=root
        / "bindings/dotnet/src/NaviApps.WindowManagement/NaviApps.WindowManagement.csproj",
        version=tomllib.loads((root / "Cargo.toml").read_text())["workspace"]["package"]["version"],
        authors="Navi Apps",
        package_files=selected,
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        input_files=[Path(__file__), *(root / relative for relative in support_inputs())],
        argv=[value for rid in args.runtime for value in ("--runtime", rid)]
        + [value for source in args.package_source for value in ("--package-source", source)],
    )


if __name__ == "__main__":
    main()
