#!/usr/bin/env python3
"""Build or verify this SDK's independently installable macOS C ABI framework."""

from pathlib import Path

from _tooling import load


def builder():
    return load("native").NativeBuilder(
        Path(__file__).resolve().parents[1],
        symbol_prefix="window_management_",
        minimum_macos="26.0",
    )


if __name__ == "__main__":
    load("native").main([builder()])
