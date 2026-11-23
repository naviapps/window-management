#!/usr/bin/env python3
"""Run the SDK's independent Git Rust and installed macOS C fixtures."""

from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent


def main(argv=None):
    load("installed_consumers").check_installed(
        root=ROOT,
        git_url="https://github.com/naviapps/window-management.git",
        rust_packages=("window-management",),
        framework=(
            "Artifacts/CWindowManagement.xcframework/macos-arm64_x86_64/CWindowManagement.framework"
        ),
        header="window_management.h",
        argv=argv,
    )


if __name__ == "__main__":
    main()
