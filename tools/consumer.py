#!/usr/bin/env python3
"""Run the SDK-owned Swift fixture against only installable sources and artifacts."""

from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent


def main(argv=None):
    load("consumers").check_swift(
        root=ROOT,
        inputs=("Package.swift", "Sources", "Tests", "Artifacts", "ThirdParty", "LICENSE"),
        fixture=ROOT / "fixtures/swift-consumer",
        executables=("WindowManagementConsumer",),
        argv=argv,
    )


if __name__ == "__main__":
    main()
