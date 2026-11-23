"""Resolve the mise launcher attested for the owned macOS CI base."""

import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

LAUNCHER = Path("/opt/homebrew/Cellar/mise/2026.10.24/bin/mise")
LAUNCHER_SHA256 = "fc886cf18eb741f5fd0088eb96fb8c66c612fc653468bbc65581beebd6682a01"
LEGACY_MANIFEST_SHA256 = "6f1e09cc773dafd95282b559efa2b45aada6ab221649df7aed54819e7ab237da"
VERSION = "2026.10.24 macos-arm64 (2026-10-30)"


def matches(path: Path, sha256: str) -> bool:
    if path.resolve(strict=True) != path or not path.is_file():
        return False
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest() == sha256


def main() -> None:
    if any(os.environ.get(name) for name in ("GH_TOKEN", "GITHUB_TOKEN", "MISE_GITHUB_TOKEN")):
        raise SystemExit("Prepared mise must run without GitHub credentials.")

    try:
        tools_root = Path(os.environ["NAVI_CI_TOOLS_ROOT"])
        if not tools_root.is_absolute():
            raise ValueError
        tools_root = tools_root.resolve(strict=True)
        manifest_sha256 = os.environ.get("NAVI_CI_PREPARED_MANIFEST_SHA256", LEGACY_MANIFEST_SHA256)
        if (
            not re.fullmatch(r"[0-9a-f]{64}", manifest_sha256)
            or not matches(tools_root / "manifest.json", manifest_sha256)
            or not matches(LAUNCHER, LAUNCHER_SHA256)
            or not os.access(LAUNCHER, os.X_OK)
        ):
            raise ValueError
        result = subprocess.run(
            [LAUNCHER, "--version"], cwd=tools_root, capture_output=True, check=True, timeout=15
        )
        if result.stdout != f"{VERSION}\n".encode():
            raise ValueError
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        raise SystemExit("Prepared mise does not match the attested macOS CI base.") from None

    print(f"Verified prepared mise {VERSION}", file=sys.stderr)
    print(LAUNCHER)
