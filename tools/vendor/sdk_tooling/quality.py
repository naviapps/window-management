"""Run scoped first-party static checks without building or operating the product."""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tomllib
from pathlib import Path, PurePosixPath, PureWindowsPath

SOURCE_MANIFEST = ".navi-ci-source-files.json"
SOURCE_MANIFEST_LIMIT = 16 * 1024 * 1024

EXCLUDED = {
    ".git",
    ".jj",
    ".build",
    ".native-build",
    ".vercel",
    "Artifacts",
    "ThirdParty",
    "vendor",
    "node_modules",
    "target",
    "bin",
    "obj",
    "build",
    "DerivedData",
    "dist",
}


def _manifest_files(root):
    name = os.environ.get("NAVI_CI_SOURCE_FILES")
    digest = os.environ.get("NAVI_CI_SOURCE_FILES_SHA256")
    if name is None and digest is None:
        return None
    if not name or not digest or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Source selection requires a manifest path and SHA-256")
    path = Path(name)
    if (
        not path.is_absolute()
        or str(path) != name
        or name.startswith("//")
        or ".." in path.parts
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
        or path.name != SOURCE_MANIFEST
        or path.parent.resolve(strict=True) != root
        or path.is_symlink()
        or not path.is_file()
    ):
        raise ValueError("Source selection requires the ordinary workspace manifest")
    with path.open("rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Source selection manifest must be an ordinary file")
        data = stream.read(SOURCE_MANIFEST_LIMIT + 1)
    if len(data) > SOURCE_MANIFEST_LIMIT or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("Source selection manifest exceeds its bound or differs from SHA-256")
    document = json.loads(data.decode("utf-8"))
    if (
        not isinstance(document, dict)
        or set(document) != {"version", "files"}
        or type(document["version"]) is not int
        or document["version"] != 1
        or not isinstance(document["files"], list)
        or not document["files"]
        or len(document["files"]) > 100000
        or not all(isinstance(item, str) for item in document["files"])
    ):
        raise ValueError("Invalid source selection manifest")
    names = document["files"]
    if names != sorted(set(names)):
        raise ValueError("Source selection names must be sorted and unique")
    for name in names:
        relative = PurePosixPath(name)
        if (
            not name
            or not relative.parts
            or relative.is_absolute()
            or relative.as_posix() != name
            or ".." in relative.parts
            or "\\" in name
            or PureWindowsPath(name).drive
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or name.casefold() == SOURCE_MANIFEST
        ):
            raise ValueError("Unsafe source selection name: " + name)
    return names


def source_files(root):
    """Select Git source or an explicitly bound CI snapshot, rejecting linked inputs."""
    root = Path(root).resolve(strict=True)
    names = _manifest_files(root)
    explicit = names is not None
    if names is None:
        data = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        )
        names = sorted(set(data.decode().rstrip("\0").split("\0")) - {""})
    result = []
    for name in names:
        relative = Path(name)
        directories = relative.parts[:-1]
        # Match directory names exactly: a Swift target named Target is source,
        # and an extensionless source file named build is not a build directory.
        if any(part in EXCLUDED for part in directories):
            continue
        path = root / relative
        if not path.is_file():
            if explicit:
                raise ValueError("Selected source is missing or not an ordinary file: " + name)
            continue
        resolved = path.resolve()
        if os.fspath(resolved) != os.fspath(path):
            # The root is already canonical. Probe the individual components
            # only when resolution changed the path. Compare exact spellings
            # to catch links differing only by case on case-sensitive Windows directories.
            if path.is_symlink() or any(
                parent.is_symlink() for parent in path.parents if parent != root
            ):
                raise ValueError("Static checks require ordinary first-party files: " + name)
            if not resolved.is_relative_to(root):
                raise ValueError("Static check input escapes the repository: " + name)
        # DocC validates catalog Markdown; generic formatting rewrites its symbol links.
        if relative.suffix == ".md" and any(part.endswith(".docc") for part in directories):
            continue
        result.append(name)
    return result


def tool_pins(root):
    return tomllib.loads((root / "mise.toml").read_text()).get("tools", {})


def tool(root, name, configuration=None):
    """Require the repository's pinned developer tool; never install implicitly."""
    selected = configuration or name
    tools = tool_pins(root)
    if selected not in tools:
        raise RuntimeError(
            f"Required tool {name} is not pinned; add {selected} to {root}/mise.toml"
        )
    return resolve_tool(root, name, tools[selected])


def resolve_tool(root, name, pin):
    executable = shutil.which(name)
    if executable is None:
        raise RuntimeError(f"Missing {name}; run mise install in {root}")
    version = pin["version"] if isinstance(pin, dict) else pin
    actual = subprocess.check_output([executable, "--version"], text=True).strip()
    if not re.search(r"(?<![\d.])" + re.escape(version) + r"(?![\d.])", actual):
        raise RuntimeError(f"{name} differs from mise.toml: {actual}")
    return executable


def workflow_linters(root):
    """Pass declared linters explicitly; do not let actionlint silently skip them."""
    pins = tool_pins(root)
    host = {"darwin": "macos", "win32": "windows"}.get(sys.platform, sys.platform)
    arguments = []
    for name, key in (("shellcheck", "shellcheck"), ("pyflakes", "pypi:pyflakes")):
        pin = pins.get(key)
        platforms = pin.get("os") if isinstance(pin, dict) else None
        path = ""
        if pin is not None and (platforms is None or host in platforms):
            path = Path(resolve_tool(root, name, pin)).absolute()
        # An empty flag disables PATH discovery for undeclared or out-of-scope tools.
        arguments.append(f"-{name}={path}")
    return arguments


def run(root, arguments, *, env=None):
    print("[quality] " + " ".join(map(str, arguments[:6])), flush=True)
    subprocess.run(list(map(str, arguments)), cwd=root, env=env, check=True)


def format_with_dprint(root, paths, *, write):
    run(
        root,
        [tool(root, "dprint"), "fmt" if write else "check", "--config", ".dprint.json", *paths],
    )


def check(root, *, write=False, languages=None, dotnet=False):
    root = Path(root).resolve(strict=True)
    files = source_files(root)
    chosen = set(languages or ("python", "swift", "rust", "c", "shell", "data"))

    def by_suffix(*suffixes):
        return ["./" + name for name in files if Path(name).suffix in suffixes]

    if "python" in chosen and (paths := by_suffix(".py")):
        executable = tool(root, "ruff")
        if not write:
            run(root, [executable, "check", *paths])
        run(root, [executable, "format", *([] if write else ["--check"]), *paths])
    if "data" in chosen and (root / ".dprint.json").is_file():
        paths = [
            "./" + name
            for name in files
            if Path(name).suffix in {".json", ".toml", ".yml", ".yaml", ".md"}
            and "fixtures" not in Path(name).parts
            and not Path(name).name.upper().startswith(("CHANGELOG", "HISTORY"))
        ]
        if paths:
            format_with_dprint(root, paths, write=write)
    if "shell" in chosen and (paths := by_suffix(".sh")) and os.name != "nt":
        format_with_dprint(root, paths, write=write)
        if not write:
            for path in paths:
                run(root, ["bash", "-n", path])
            run(root, [tool(root, "shellcheck"), *paths])
    if "c" in chosen and (paths := by_suffix(".c", ".h")) and os.name != "nt":
        run(
            root,
            [
                tool(root, "clang-format", "pypi:clang-format"),
                *(["-i"] if write else ["--dry-run", "--Werror"]),
                *paths,
            ],
        )
    if "swift" in chosen and (paths := by_suffix(".swift")) and sys.platform == "darwin":
        run(
            root,
            [
                "xcrun",
                "swift-format",
                "format" if write else "lint",
                *(["--in-place"] if write else ["--strict"]),
                "--parallel",
                *paths,
            ],
        )
        if not write:
            env = dict(os.environ, SCRIPT_INPUT_FILE_COUNT=str(len(paths)))
            env.update({f"SCRIPT_INPUT_FILE_{i}": str(root / path) for i, path in enumerate(paths)})
            run(
                root,
                [
                    tool(root, "swiftlint"),
                    "lint",
                    "--strict",
                    "--quiet",
                    "--disable-sourcekit",
                    "--config",
                    str(root / ".swiftlint.yml"),
                    "--use-script-input-files",
                ],
                env=env,
            )
    if "rust" in chosen and (root / "Cargo.toml").is_file():
        for manifest in [root / "Cargo.toml", root / "bindings/web/rust/Cargo.toml"]:
            if manifest.is_file():
                run(
                    root,
                    [
                        "cargo",
                        "fmt",
                        "--manifest-path",
                        manifest,
                        "--all",
                        *([] if write else ["--", "--check"]),
                    ],
                )
        if not write:
            run(root, [tool(root, "cargo-machete", "github:bnjbvr/cargo-machete"), root])
    if dotnet and (root / "bindings/dotnet").is_dir():
        for directory in ["bindings/dotnet", "fixtures/windows"]:
            if (root / directory).is_dir():
                run(
                    root,
                    [
                        os.environ.get("DOTNET_BIN", "dotnet"),
                        "format",
                        "whitespace",
                        directory,
                        "--folder",
                        *([] if write else ["--verify-no-changes"]),
                        "--exclude",
                        "obj",
                        "bin",
                    ],
                )
    if not write and "data" in chosen:
        workflows = [
            "./" + name
            for name in files
            if name.startswith(".github/workflows/") and Path(name).suffix in {".yml", ".yaml"}
        ]
        if workflows:
            configuration = next(
                (
                    root / name
                    for name in (".github/actionlint.yaml", ".github/actionlint.yml")
                    if name in files
                ),
                None,
            )
            config_args = ["-config-file", configuration] if configuration is not None else []
            run(root, [tool(root, "actionlint"), *config_args, *workflow_linters(root), *workflows])
    return 0


def add_arguments(parser):
    parser.add_argument("operation", choices=["check", "format", "prepared-mise"])
    parser.add_argument(
        "--language", action="append", choices=["python", "swift", "rust", "c", "shell", "data"]
    )
    parser.add_argument(
        "--dotnet",
        action="store_true",
        help="Include managed whitespace; build analyzers run in managed acceptance",
    )


def run_operation(args, *, root):
    if args.operation == "prepared-mise":
        if args.language or args.dotnet:
            raise SystemExit("prepared-mise does not accept check or format options.")
        from . import prepared_mise

        return prepared_mise.main()
    return check(
        root,
        write=args.operation == "format",
        languages=args.language,
        dotnet=args.dotnet,
    )


def main(argv=None, *, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser)
    return run_operation(parser.parse_args(argv), root=root or Path.cwd())
