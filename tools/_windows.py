"""Select the Windows x64 fixture target with the producer's tooling revision."""

import argparse
import platform
import sys

from _tooling import add_candidate_options, select_candidate

TARGET = "x86_64-pc-windows-msvc"
RID = "win-x64"


def require_native_x64(parser):
    if platform.machine().lower() not in ("amd64", "x86_64"):
        parser.error(
            "Windows ARM64 requires --tooling-source and --tooling-revision for x64 acceptance"
        )


def consumer_options(argv=None):
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    add_candidate_options(parser)
    parser.add_argument("--windows-architecture", choices=("x64",))
    args, remaining = parser.parse_known_args(argv)
    select_candidate(parser, args)
    if sys.platform == "win32":
        if args.tooling_source is None:
            require_native_x64(parser)
        else:
            remaining += ["--windows-architecture", "x64"]
    elif args.windows_architecture:
        parser.error("--windows-architecture requires Windows")
    return remaining
