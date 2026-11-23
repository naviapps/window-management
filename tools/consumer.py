#!/usr/bin/env python3
"""Build and run this SDK's external Swift consumer."""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "fixtures/swift-consumer"
INPUTS = ("Package.swift", "Sources", "Tests", "Artifacts", "ThirdParty", "LICENSE")
EXECUTABLE = "WindowManagementConsumer"
SYSTEM_ENVIRONMENT = (
    "HOME",
    "CFFIXED_USER_HOME",
    "DEVELOPER_DIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
)


def stage(source, destination, names):
    destination.mkdir()
    ignored = shutil.ignore_patterns(".git", ".build", ".native-build", ".swiftpm", "__pycache__")
    for name in names:
        path = source / name
        if path.is_dir() and not path.is_symlink():
            shutil.copytree(path, destination / name, symlinks=True, ignore=ignored)
        else:
            shutil.copy2(path, destination / name, follow_symlinks=False)
    for path in destination.rglob("*"):
        if path.is_symlink() and (
            Path(os.readlink(path)).is_absolute()
            or not path.resolve(strict=True).is_relative_to(destination)
        ):
            raise ValueError(f"Swift consumer link escapes its staged package: {path}")


def run_consumer(*, build_system, warnings_as_errors):
    with tempfile.TemporaryDirectory(prefix="swift-consumer-") as directory:
        work = Path(directory).resolve()
        consumer = work / "consumer"
        stage(ROOT, work / "sdk", INPUTS)
        stage(FIXTURE, consumer, ("Package.swift", "Sources"))
        env = {key: os.environ[key] for key in SYSTEM_ENVIRONMENT if key in os.environ}
        env.update(
            PATH="/usr/bin:/bin:/usr/sbin:/sbin",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
        )
        subprocess.run(
            [
                "xcrun",
                "swift",
                "run",
                "--cache-path",
                str(work / "cache"),
                "--config-path",
                str(work / "config"),
                "--security-path",
                str(work / "security"),
                "--disable-dependency-cache",
                *(["--build-system", build_system] if build_system else []),
                "-Xswiftc",
                "-strict-concurrency=complete",
                *(["-Xswiftc", "-warnings-as-errors"] if warnings_as_errors else []),
                EXECUTABLE,
            ],
            cwd=consumer,
            env=env,
            check=True,
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--distribution", action="store_true", help="Run the full distribution check"
    )
    parser.add_argument(
        "--git-config", type=Path, help="Explicit Git configuration for distribution"
    )
    parser.add_argument(
        "--mirror-config", type=Path, help="Explicit SwiftPM mirrors for distribution"
    )
    parser.add_argument(
        "--build-system", choices=("native", "swiftbuild"), help="SwiftPM build system"
    )
    parser.add_argument(
        "--allow-warnings", action="store_true", help="Do not pass -warnings-as-errors to Swift"
    )
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Swift native consumer acceptance requires macOS")
    if args.distribution or args.git_config or args.mirror_config:
        from _tooling import load

        load("consumers").run_swift_consumer(
            root=ROOT,
            inputs=INPUTS,
            fixture=FIXTURE,
            executables=(EXECUTABLE,),
            git_config=args.git_config,
            mirror_config=args.mirror_config,
            build_system=args.build_system,
            warnings_as_errors=not args.allow_warnings,
        )
    else:
        run_consumer(build_system=args.build_system, warnings_as_errors=not args.allow_warnings)


if __name__ == "__main__":
    main()
