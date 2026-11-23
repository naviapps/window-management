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

    load("consumers").check_c(
        source=root / "crates/ffi/tests/c/abi.c",
        include_dirs=(native.ffi / "include",),
        library=framework,
        work_parent=root / ".native-build",
        argv=options,
    )
    verify_candidate()
    print(root.name + " C ABI fixture passed.")


if __name__ == "__main__":
    main()
