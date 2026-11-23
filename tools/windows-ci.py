"""Run Windows x64 acceptance with the SDKs installed by GitHub Actions."""

import os
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    if sys.platform != "win32":
        raise SystemExit("Hosted Windows SDK acceptance requires Windows.")
    if len(sys.argv) < 2:
        raise SystemExit("Specify the SDK-owned Windows acceptance command.")

    temp = Path(os.environ.get("RUNNER_TEMP", ""))
    if not temp.is_absolute() or not temp.is_dir():
        raise SystemExit("Set RUNNER_TEMP to an absolute runner temporary directory.")
    dotnet = shutil.which("dotnet.exe")
    if not dotnet:
        raise SystemExit("The pinned x64 .NET SDK was not installed.")

    subprocess.run(
        [sys.executable, "-E", "-S", "-B", *sys.argv[1:]],
        cwd=Path(__file__).resolve().parents[1],
        env=dict(os.environ, DOTNET_BIN=dotnet, NAVI_CI_ARTIFACTS=str(temp / "sdk-acceptance")),
        check=True,
    )


if __name__ == "__main__":
    main()
