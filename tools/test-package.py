#!/usr/bin/env python3
"""Run this SDK's package fixture through the pinned local-feed consumer driver."""

from pathlib import Path

from _tooling import load, verify_candidate
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
    verify_candidate()


if __name__ == "__main__":
    main()
