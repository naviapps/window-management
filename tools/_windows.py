"""Select the Windows x64 fixture target on supported Windows hosts."""

import argparse
import sys

TARGET = "x86_64-pc-windows-msvc"
RID = "win-x64"


def consumer_options(argv=None):
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--windows-architecture", choices=("x64",))
    args, remaining = parser.parse_known_args(argv)
    if sys.platform == "win32":
        remaining += ["--windows-architecture", "x64"]
    elif args.windows_architecture:
        parser.error("--windows-architecture requires Windows")
    return remaining
