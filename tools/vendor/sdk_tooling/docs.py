"""Check supplied DocC catalogs against symbol graphs produced by their own SDK."""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from .artifacts import publish


def check_catalogs(
    root,
    catalogs,
    *,
    output,
    bundle_identifier_prefix,
    runner=None,
    graph_arguments=(),
    convert_arguments=(),
    symbol_validator=None,
    retain_archives=False,
):
    root = Path(root).resolve()
    catalogs = list(map(Path, catalogs))
    convert_arguments = list(convert_arguments)
    linking_flag = "--enable-experimental-external-link-support"
    if linking_flag not in convert_arguments:
        convert_arguments.append(linking_flag)
    execute = runner or subprocess.run
    result = execute(
        ["swift", "package", "dump-symbol-graph", *graph_arguments],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise RuntimeError(result.stdout)
    prefix = "Files written to "
    paths = []
    for line in result.stdout.splitlines():
        if line.startswith(prefix):
            path = Path(line[len(prefix) :])
            paths.append((path if path.is_absolute() else root / path).resolve())
    if len(paths) != 1 or not paths[0].is_relative_to((root / ".build").resolve()):
        raise ValueError("SwiftPM did not report one owned symbol graph directory")
    graphs = {}
    for path in paths[0].glob("*.json"):
        data = json.loads(path.read_text())
        graphs.setdefault(data["module"]["name"], []).append((path, data))
    if not catalogs:
        raise ValueError("No SDK documentation catalogs")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix="docc-") as directory:
        work = Path(directory)
        archives = []
        for catalog in catalogs:
            module = catalog.stem
            if not graphs.get(module):
                raise ValueError("No public symbols for " + module)
            if symbol_validator is not None:
                symbol_validator(module, [data for _, data in graphs[module]])
            selected = work / module
            selected.mkdir()
            for source, _ in graphs[module]:
                shutil.copy2(source, selected / source.name)
            archive = work / (module + ".doccarchive")
            execute(
                [
                    "xcrun",
                    "docc",
                    "convert",
                    str(catalog),
                    "--additional-symbol-graph-dir",
                    str(selected),
                    "--fallback-display-name",
                    module,
                    "--fallback-bundle-identifier",
                    bundle_identifier_prefix + module,
                    "--warnings-as-errors",
                    "--output-path",
                    str(archive),
                    *convert_arguments,
                    *[
                        value
                        for dependency in archives
                        for value in ("--dependency", str(dependency))
                    ],
                ],
                cwd=root,
                check=True,
            )
            for name in ("linkable-entities.json", "link-hierarchy.json"):
                path = archive / name
                try:
                    if path.is_symlink() or not path.is_file():
                        raise ValueError("Missing link metadata")
                    json.loads(path.read_text())
                except (OSError, ValueError):
                    raise ValueError(
                        "DocC did not emit valid link metadata for " + module + ": " + name
                    ) from None
            archives.append(archive)
            print("DocC public symbols and guide verified: " + module)
        if retain_archives:
            for archive in archives:
                publish(archive, output / archive.name, lambda: None)
