"""Load one verified immutable developer-tool revision; normal SDK users do not run this."""

import hashlib
import importlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "naviapps/sdk-tooling"
URL = "https://github.com/" + REPOSITORY + ".git"
_candidate = None
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
        raise RuntimeError(
            "Pinned SDK tooling Git operation failed; prepare its source/cache before retrying"
        ) from None


def verify(source, revision):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("SDK tooling source/cache must be an ordinary directory")
    if git(source, "rev-parse", "HEAD").decode().strip() != revision:
        raise ValueError("SDK tooling revision differs from tools/tooling-sources.json")
    if git(source, "status", "--porcelain=v1", "--untracked-files=all").strip():
        raise ValueError("Pinned SDK tooling source has local changes")
    for entry in git(source, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not entry:
            continue
        identity, name = entry.split(b"\t", 1)
        mode, kind, expected = identity.split()
        path = source / name.decode("utf-8")
        if (
            mode not in (b"100644", b"100755")
            or kind != b"blob"
            or path.is_symlink()
            or not path.is_file()
        ):
            raise ValueError("SDK tooling contains an unsafe or missing source file")
        data = path.read_bytes()
        actual = (
            hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest().encode()
        )
        if actual != expected:
            raise ValueError("SDK tooling cache bytes differ from the pinned Git tree")
    if any((source / "sdk_tooling").rglob("*.pyc")):
        raise ValueError("Immutable SDK tooling contains generated Python bytecode")
    return source.resolve()


def source():
    pins = json.loads((ROOT / "tools/tooling-sources.json").read_text())
    if set(pins) != {REPOSITORY} or not re.fullmatch(r"[a-f0-9]{40}", pins[REPOSITORY]):
        raise ValueError("SDK tooling requires one canonical immutable Git revision")
    revision = pins[REPOSITORY]
    remote = URL
    if os.environ.get("NAVI_CI_SOURCES"):
        manifest = Path(os.environ["NAVI_CI_SOURCES"])
        selected = [
            entry for entry in json.loads(manifest.read_text()) if entry["repository"] == REPOSITORY
        ]
        if len(selected) != 1 or selected[0]["revision"] != revision or selected[0]["url"] != URL:
            raise ValueError("Isolated SDK tooling source differs from its captured pin")
        entry = selected[0]
        bundle = Path(entry["bundle"])
        if bundle.name != str(bundle) or not re.fullmatch(r"\d+\.bundle", bundle.name):
            raise ValueError("SDK tooling bundle must be a local manifest member")
        archive = manifest.parent / bundle
        if (
            archive.is_symlink()
            or hashlib.sha256(archive.read_bytes()).hexdigest() != entry["sha256"]
        ):
            raise ValueError("SDK tooling source bundle checksum differs")
        mirror = archive.with_suffix(".git")
        if (
            mirror.is_symlink()
            or git(mirror, "rev-parse", revision + "^{commit}").decode().strip() != revision
        ):
            raise ValueError("SDK tooling source mirror revision differs")
        remote = mirror.resolve().as_uri()
    if os.environ.get("NAVI_SDK_TOOLING_SOURCE"):
        return verify(Path(os.environ["NAVI_SDK_TOOLING_SOURCE"]), revision)
    default = (
        Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".cache")))
        if os.name == "nt"
        else Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    )
    cache = Path(os.environ.get("NAVI_SDK_TOOLING_CACHE", str(default / "naviapps/sdk-tooling")))
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = cache / revision
    if destination.exists() or destination.is_symlink():
        return verify(destination, revision)
    if os.environ.get("NAVI_SDK_TOOLING_OFFLINE") == "1" and remote == URL:
        raise RuntimeError("Pinned SDK tooling is absent from the offline cache")
    with tempfile.TemporaryDirectory(dir=cache, prefix=".pending-") as temporary:
        candidate = Path(temporary)
        git(None, "init", "--quiet", str(candidate))
        public_fetch_options = ("-c", "credential.helper=") if remote == URL else ()
        git(
            candidate,
            *public_fetch_options,
            "fetch",
            "--quiet",
            "--no-tags",
            "--depth=1",
            remote,
            revision,
        )
        git(candidate, "checkout", "--quiet", "--detach", "FETCH_HEAD")
        verify(candidate, revision)
        try:
            os.rename(candidate, destination)
        except OSError:
            if not destination.is_dir():
                raise
        # A concurrent publisher may have won. Verify the published bytes either way.
        return verify(destination, revision)


def load_candidate(directory, revision):
    """Return an independent loader for a byte-verified tooling checkout."""
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("A candidate SDK tooling source requires its full Git commit SHA")
    root = verify(directory, revision)
    return lambda name: load(name, _verified_root=root)


def add_candidate_options(parser, *, required=False):
    parser.add_argument(
        "--tooling-source", type=Path, required=required, help="Local approved SDK tooling checkout"
    )
    parser.add_argument(
        "--tooling-revision",
        required=required,
        help="Full Git SHA of the approved tooling checkout",
    )


def select_candidate(parser, args, *, absolute=False):
    global _candidate
    directory, revision = args.tooling_source, args.tooling_revision
    if (directory is None) != (revision is None):
        parser.error("Use --tooling-source and --tooling-revision together")
    if directory is None:
        return []
    if absolute and not directory.is_absolute():
        parser.error("Use an absolute path for the approved SDK tooling checkout")
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        parser.error("A candidate SDK tooling source requires its full Git commit SHA")
    root = verify(directory, revision)
    selected = root, revision
    if _candidate is not None and selected != _candidate:
        raise ValueError("Only one approved SDK tooling checkout may be selected")
    _candidate = selected
    return ["--tooling-source", str(root), "--tooling-revision", revision]


def candidate_selected():
    return _candidate is not None


def verify_candidate():
    if _candidate is not None:
        verify(*_candidate)


def load(name, *, _verified_root=None):
    if not re.fullmatch(r"[a-z_]+", name):
        raise ValueError("Invalid SDK tooling module")
    root = _verified_root
    if root is None:
        root = _candidate[0] if _candidate is not None else source()
    existing = sys.modules.get("sdk_tooling")
    if existing is not None and Path(existing.__file__).resolve().parent != root / "sdk_tooling":
        raise RuntimeError("Different SDK tooling revisions cannot share one Python interpreter")
    sys.path.insert(0, str(root))
    return importlib.import_module("sdk_tooling." + name)


if __name__ == "__main__":
    raise SystemExit(load("hosted_windows").main(ROOT, sys.argv[1:]))
