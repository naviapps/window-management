"""Load explicitly prepared distribution tooling from an exact Git revision."""

import hashlib
import json
import os
import re
import subprocess
import sys
from importlib import import_module
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tools/tooling-sources.json"
REPOSITORY = "naviapps/sdk-tooling"
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


def _verified_source():
    pin = json.loads(MANIFEST.read_text(encoding="utf-8"))[REPOSITORY]
    if not re.fullmatch(r"[a-f0-9]{40}", pin):
        raise ValueError("Distribution tooling requires an exact Git revision")
    if not (selected := os.environ.get("NAVI_SDK_TOOLING_SOURCE")):
        raise SystemExit(
            "Distribution checks need NAVI_SDK_TOOLING_SOURCE set to a clean SDK Tooling "
            f"checkout at {pin}. Run make check for contributor checks."
        )
    source = Path(selected).resolve(strict=True)
    if (
        Path(os.fsdecode(git(source, "rev-parse", "--show-toplevel").strip())).resolve() != source
        or git(source, "rev-parse", "HEAD").decode().strip() != pin
        or git(source, "status", "--porcelain=v1", "--untracked-files=all")
    ):
        raise ValueError(f"SDK Tooling must be a clean checkout at {pin}")
    paths = ("sdk_tooling", "tools/consumer-identity", "tools/native-dep-info")
    inputs = {}
    for record in git(source, "ls-tree", "-rz", "HEAD", "--", *paths).split(b"\0"):
        if not record:
            continue
        metadata, name = record.split(b"\t", 1)
        mode, kind, expected = metadata.split()
        relative = name.decode("utf-8")
        path = source / relative
        if mode not in (b"100644", b"100755") or kind != b"blob" or path.resolve() != path:
            raise ValueError("Invalid SDK Tooling input: " + relative)
        data = path.read_bytes()
        object_id = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if object_id.encode() != expected:
            raise ValueError("SDK Tooling source differs from its pinned bytes: " + relative)
        inputs["@sdk-tooling/" + relative] = hashlib.sha256(data).hexdigest()
    if not inputs or any((source / "sdk_tooling").rglob("*.pyc")):
        raise ValueError("SDK Tooling requires ordinary source files without bytecode")
    return source, inputs


def load(module):
    source, _ = _verified_source()
    existing = sys.modules.get("sdk_tooling")
    if existing is not None and Path(existing.__file__).resolve().parent != source / "sdk_tooling":
        raise RuntimeError("Loaded SDK Tooling differs from the selected source")
    sys.path.insert(0, str(source))
    try:
        return import_module("sdk_tooling." + module)
    finally:
        sys.path.remove(str(source))


def support_inputs():
    _, inputs = _verified_source()
    for path in (MANIFEST, Path(__file__).resolve()):
        inputs[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return inputs
