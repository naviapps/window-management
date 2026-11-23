#!/usr/bin/env python3
"""Owned Windows CI acceptance and local artifact export for this SDK."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

from sdk_tooling import vm_environment as vm
from sdk_tooling.adapters import load, python_command, support_inputs

from fixtures.distribution._windows import RID


def main(root=None, argv=None):
    root = Path(root or Path(__file__).resolve().parents[2]).resolve()
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--skip-desktop",
        action="store_true",
        help="Run ABI and package acceptance without a separate desktop fixture",
    )
    args = parser.parse_args(argv)
    output = vm.artifacts_dir()
    if sys.platform != "win32" or output is None:
        raise SystemExit("Use the owned Windows CI worker; artifact ownership must be explicit.")
    inputs = support_inputs(root)
    output.mkdir(parents=True, exist_ok=True)
    workspace = tomllib.loads((root / "Cargo.toml").read_text())
    if not Path(os.environ.get("DOTNET_BIN", "")).is_absolute():
        raise SystemExit("Set DOTNET_BIN to the absolute x64 .NET SDK executable")
    environment = {key.upper(): value for key, value in os.environ.items()}
    windows = load("windows")
    windows.target_dotnet(windows.host_architecture(), "x64", environment)

    def run(command, directory=root):
        subprocess.run(
            [str(value) for value in command], cwd=directory, env=environment, check=True
        )

    version = workspace["workspace"]["package"]["version"]
    build = root / ".native-build"
    package = build / "packages" / f"NaviApps.WindowManagement.{version}.nupkg"
    native_receipt = build / "windows" / RID / "native-build.json"
    package_receipt = package.with_suffix(".nupkg.json")
    accepted = False
    try:
        desktop = [] if args.skip_desktop else ["--desktop"]
        run(python_command(root, "fixtures/distribution/check-windows.py", *desktop))
        native_digest = hashlib.sha256(native_receipt.read_bytes()).hexdigest()
        run(python_command(root, "fixtures/distribution/pack-dotnet.py", "--runtime", RID))
        receipt_bytes = package_receipt.read_bytes()
        receipt = json.loads(receipt_bytes)
        if (
            receipt["runtimes"] != [RID]
            or receipt["nativeReceipts"] != {RID: native_digest}
            or receipt["sha256"] != hashlib.sha256(package.read_bytes()).hexdigest()
        ):
            raise ValueError("Windows package differs from the accepted x64 build")
        run(load("binding_checks").command("nuget", package))
        if inputs != support_inputs(root):
            raise ValueError("Build support changed during Windows x64 acceptance")
        if (
            receipt["sha256"] != hashlib.sha256(package.read_bytes()).hexdigest()
            or receipt_bytes != package_receipt.read_bytes()
            or native_digest != hashlib.sha256(native_receipt.read_bytes()).hexdigest()
        ):
            raise ValueError("Windows x64 package changed during installed consumer acceptance")
        accepted = True
    finally:
        # Preserve owned native failure evidence too. The host retains these as opaque data.
        directories = (RID,) if args.skip_desktop else (RID, "desktop-acceptance")
        for name in directories:
            source = build / "windows" / name
            if source.is_dir():
                shutil.copytree(source, output / "sdk-windows" / name)
        if accepted:
            for source in (package, package_receipt):
                destination = output / "sdk-packages" / source.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)


if __name__ == "__main__":
    main()
