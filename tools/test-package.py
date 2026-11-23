#!/usr/bin/env python3
"""Restore and run this SDK's NuGet fixture from an isolated local feed."""

from pathlib import Path

from _tooling import load
from _windows import consumer_options


def main(argv=None):
    options = consumer_options(argv)
    root = Path(__file__).resolve().parents[1]
    load("consumers").check_nuget(
        package_id="NaviApps.WindowManagement",
        fixture=root / "bindings/dotnet/tests/PackageConsumer/Program.cs",
        work_parent=root / ".native-build/packages",
        argv=options,
    )


if __name__ == "__main__":
    main()
