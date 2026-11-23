"""Select the verified SDK Tooling source for SDK-owned distribution adapters."""

import os
import re
import subprocess
import sys
import tomllib
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = "sdk_tooling/source_gate.py"
TOOL = re.compile(
    r"uvx --from git\+https://github\.com/naviapps/sdk-tooling\.git@([a-f0-9]{40}) sdk-tooling"
)
sys.dont_write_bytecode = True


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


@cache
def _gate():
    task = tomllib.loads((ROOT / "mise.toml").read_text(encoding="utf-8"))["tasks"]["sdk-tooling"]
    if not (match := TOOL.fullmatch(task["run"])):
        raise ValueError("Distribution tooling requires an exact Git revision")
    pin = match[1]
    if not (selected := os.environ.get("NAVI_SDK_TOOLING_SOURCE")):
        raise SystemExit(
            "Set NAVI_SDK_TOOLING_SOURCE to a clean SDK Tooling checkout at "
            f"{pin} to run SDK-owned distribution adapters."
        )
    source = Path(selected).resolve(strict=True)
    path = source / GATE
    pinned = git(source, "show", pin + ":" + GATE)
    if path.resolve() != path or path.read_bytes() != pinned:
        raise ValueError("SDK Tooling source gate differs from its pinned bytes")
    scope = {}
    exec(compile(pinned, str(path), "exec"), scope)
    return source, pin, scope


def load(module):
    source, pin, gate = _gate()
    gate["verify"](source, pin, git)
    return gate["load"](source, module)


def support_inputs():
    source, pin, gate = _gate()
    _, inputs = gate["verify"](source, pin, git)
    return gate["support_inputs"](ROOT, inputs)
