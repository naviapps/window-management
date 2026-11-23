"""Check or format first-party SDK sources with the tools pinned in mise.toml."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_DIRECTORIES = {
    ".build",
    ".git",
    ".jj",
    ".native-build",
    ".vercel",
    "Artifacts",
    "DerivedData",
    "ThirdParty",
    "bin",
    "build",
    "dist",
    "node_modules",
    "obj",
    "target",
    "vendor",
}


def run(*args, env=None):
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def source_files():
    tracked = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
    )
    files = []
    for name in sorted(set(os.fsdecode(tracked).split("\0")) - {""}):
        relative = Path(name)
        directories = relative.parts[:-1]
        if EXCLUDED_DIRECTORIES.intersection(directories):
            continue
        if relative.suffix == ".md" and any(part.endswith(".docc") for part in directories):
            continue
        path = ROOT / relative
        if not path.is_file():
            continue
        if path.resolve(strict=True) != path:
            raise ValueError(f"Source checks require ordinary repository files: {name}")
        files.append("./" + relative.as_posix())
    return files


def workflow_linters():
    arguments = []
    for name in ("shellcheck", "pyflakes"):
        executable = shutil.which(name) if os.name != "nt" else ""
        if executable is None:
            raise RuntimeError(f"{name} is required to check workflow scripts. Run mise install.")
        arguments.append(f"-{name}={executable}")
    return arguments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check", "format"))
    parser.add_argument("--dotnet", action="store_true", help="Include .NET whitespace")
    args = parser.parse_args()
    write = args.operation == "format"
    files = source_files()

    def matching(*suffixes):
        return [name for name in files if name.endswith(suffixes)]

    if sources := matching(".py"):
        if not write:
            run("ruff", "check", *sources)
        run("ruff", "format", *([] if write else ["--check"]), *sources)

    docs = [
        name
        for name in matching(".json", ".md", ".toml", ".yaml", ".yml")
        if "fixtures" not in Path(name).parts
        and not Path(name).name.upper().startswith(("CHANGELOG", "HISTORY"))
    ]
    if docs:
        run("dprint", "fmt" if write else "check", "--config", ".dprint.json", *docs)

    if os.name != "nt":
        if shell := matching(".sh"):
            run("dprint", "fmt" if write else "check", "--config", ".dprint.json", *shell)
            if not write:
                for name in shell:
                    run("bash", "-n", name)
                run("shellcheck", *shell)
        if c := matching(".c", ".h"):
            run("clang-format", *(["-i"] if write else ["--dry-run", "--Werror"]), *c)

    if sys.platform == "darwin" and (swift := matching(".swift")):
        if write:
            run("xcrun", "swift-format", "format", "--in-place", "--parallel", *swift)
        else:
            run("xcrun", "swift-format", "lint", "--strict", "--parallel", *swift)
            env = dict(os.environ, SCRIPT_INPUT_FILE_COUNT=str(len(swift)))
            env.update(
                {f"SCRIPT_INPUT_FILE_{index}": str(ROOT / name) for index, name in enumerate(swift)}
            )
            run(
                "swiftlint",
                "lint",
                "--strict",
                "--quiet",
                "--disable-sourcekit",
                "--config",
                ".swiftlint.yml",
                "--use-script-input-files",
                env=env,
            )

    for manifest in ("Cargo.toml", "bindings/web/rust/Cargo.toml"):
        if (ROOT / manifest).is_file():
            run(
                "cargo",
                "fmt",
                "--manifest-path",
                manifest,
                "--all",
                *([] if write else ["--", "--check"]),
            )
    if not write:
        run("cargo-machete", ROOT)

    if args.dotnet:
        for directory in ("bindings/dotnet", "fixtures/windows"):
            if (ROOT / directory).is_dir():
                run(
                    os.environ.get("DOTNET_BIN", "dotnet"),
                    "format",
                    "whitespace",
                    directory,
                    "--folder",
                    *([] if write else ["--verify-no-changes"]),
                    "--exclude",
                    "obj",
                    "bin",
                )

    if not write:
        workflows = [
            name for name in matching(".yml", ".yaml") if name.startswith("./.github/workflows/")
        ]
        if workflows:
            run("actionlint", *workflow_linters(), *workflows)


if __name__ == "__main__":
    main()
