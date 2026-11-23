#!/usr/bin/env python3
"""Compile and run this SDK's C ABI fixture against its native library."""

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

    load("consumers").check_c(
        source=root / "crates/ffi/tests/c/abi.c",
        include_dirs=(native.ffi / "include",),
        library=framework,
        work_parent=root / ".native-build",
        argv=options,
    )
    print(root.name + " C ABI fixture passed.")


if __name__ == "__main__":
    main()
