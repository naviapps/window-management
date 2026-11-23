"""Import this checkout's build support and fingerprint its sources."""

import os
import subprocess
import sys
from importlib import import_module
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "tools/vendor"
sys.dont_write_bytecode = True


def load(module):
    sys.path.insert(0, str(SUPPORT))
    try:
        return import_module("sdk_tooling." + module)
    finally:
        sys.path.remove(str(SUPPORT))


def support_inputs():
    sources = [
        path
        for path in SUPPORT.rglob("*")
        if path.suffix in {".py", ".rs", ".toml", ".lock"} and path.is_file()
    ]
    return load("artifacts").hashes([Path(__file__), *sources], ROOT)


def git(root, *args):
    command = ["git", "-c", "core.hooksPath=" + os.devnull]
    if root is not None:
        command += ["-C", str(root)]
    try:
        return subprocess.check_output(
            command + list(args),
            env=dict(
                os.environ,
                GIT_TERMINAL_PROMPT="0",
                GIT_NO_REPLACE_OBJECTS="1",
                GIT_NO_LAZY_FETCH="1",
            ),
            stderr=subprocess.PIPE,
            timeout=60,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise RuntimeError("SDK source Git operation failed") from None
