"""Offline provenance and owned registry notices for selected Cargo FFI graphs.

Package properties expose Cargo descriptors for private build orchestration.
provenance() returns only portable identities and relative file hashes. Registry
notices and explicit maintainer Rust-runtime retention are separate operations;
normal builds validate retained runtime notices without requiring compiler docs.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
from collections.abc import Sequence
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

_SHA256 = re.compile(r"[a-f0-9]{64}")
_GENERATED = re.compile(r"[A-Za-z0-9_-]+-[0-9][A-Za-z0-9.+-]*")
_SKIP = {".git", ".jj", "target", ".native-build", "Artifacts", "ThirdParty", "__pycache__"}
_RUNTIME = ("LICENSE-APACHE", "LICENSE-MIT", "COPYRIGHT", "COPYRIGHT-library.html")


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def _relative(name):
    path = PurePosixPath(name)
    if (
        not path.parts
        or path.is_absolute()
        or ".." in path.parts
        or "\\" in name
        or any(":" in part or part in ("", ".") for part in path.parts)
    ):
        raise RuntimeError("Unsafe relative source or notice path")
    return path


def _read(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Source or notice must be a regular file")
    return path.read_bytes()


def notice_root(root, relative="ThirdParty"):
    """Select a repository-owned notice tree without crossing links or boundaries."""
    root = Path(root).resolve()
    relative = _relative(str(relative))
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError("Notice directory must not contain a symlink")
    return current


def _files(root, *, exclude=()):
    """Reject links, including directory links, before reading a tree."""
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("Source or notice directory must not be a link")
    result = {}
    for directory, names, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in list(names):
            if (base / name).is_symlink():
                raise RuntimeError("Source or notice directory contains a link")
            if name in exclude:
                names.remove(name)
        for name in files:
            if name not in exclude:
                path = base / name
                result[path.relative_to(root).as_posix()] = _read(path)
    return dict(sorted(result.items()))


def _hashes(files):
    return {name: _hash(data) for name, data in sorted(files.items())}


def _source_file(path, boundary):
    """Read a build input without following a link inside its source boundary."""
    path, boundary = Path(os.path.abspath(path)), Path(boundary)
    if not path.is_relative_to(boundary):
        raise RuntimeError("Build input escapes its selected source root")
    current = boundary
    for part in path.relative_to(boundary).parts:
        current = current / part
        if current.is_symlink():
            raise RuntimeError("Selected build source contains a link")
    return _read(path)


def _build_metadata_files(package, boundary):
    """Manifests and build scripts only; compiler dep-info owns Rust inputs."""
    crate = Path(package["manifest_path"]).parent
    files = {}
    for parent in (crate, *crate.parents):
        if not parent.is_relative_to(boundary):
            break
        path = parent / "Cargo.toml"
        if path.exists() or path.is_symlink():
            files[path.relative_to(boundary).as_posix()] = _source_file(path, boundary)
    manifest = tomllib.loads(_source_file(crate / "Cargo.toml", boundary).decode())
    scripts = [
        Path(target["src_path"])
        for target in package.get("targets", [])
        if "custom-build" in target.get("kind", [])
    ]
    if not scripts:
        build = manifest.get("package", {}).get("build")
        if build is not False:
            path = crate / (build if isinstance(build, str) else "build.rs")
            if isinstance(build, str) or path.exists() or path.is_symlink():
                scripts.append(path)
    for path in scripts:
        path = Path(os.path.abspath(path))
        data = _source_file(path, boundary)
        files[path.relative_to(boundary).as_posix()] = data
    return dict(sorted(files.items()))


def _source(value):
    kind, separator, remote = value.partition("+")
    url = urlsplit(remote)
    if (
        not separator
        or kind not in ("registry", "sparse", "git")
        or url.scheme not in ("https", "http", "ssh")
        or not url.hostname
        or url.password
        or url.username
        and url.scheme != "ssh"
        or any(word in url.query.lower() for word in ("token", "password", "secret"))
    ):
        raise RuntimeError("Dependency source must be a credential-free remote identity")
    return value


def _command(arguments, root, env, *, operation):
    try:
        return subprocess.check_output(
            arguments, cwd=root, env=env, stderr=subprocess.PIPE, timeout=120
        )
    except subprocess.TimeoutExpired:
        failure = "timed out"
    except subprocess.CalledProcessError as error:
        failure = f"exited with status {error.returncode}"
    except OSError:
        failure = "could not start or communicate with the subprocess"
    except subprocess.SubprocessError:
        failure = "subprocess failed"
    # Use only the fixed operation label and avoid retaining child diagnostics.
    raise RuntimeError(
        f"Offline Cargo dependency inspection failed ({operation}): {failure}"
    ) from None


def _archive(path, directory, checksum):
    content = _read(path)
    if not _SHA256.fullmatch(checksum) or _hash(content) != checksum:
        raise RuntimeError("Registry archive differs from its locked checksum")
    result = {}
    with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as archive:
        for member in archive:
            name = _relative(member.name)
            if name.parts[0] != directory:
                raise RuntimeError("Registry archive has an unexpected package root")
            if member.isdir():
                continue
            if not member.isfile() or len(name.parts) < 2:
                raise RuntimeError("Registry archive contains a link or unsupported entry")
            relative = PurePosixPath(*name.parts[1:]).as_posix()
            if relative in result:
                raise RuntimeError("Registry archive contains duplicate source files")
            with archive.extractfile(member) as stream:
                result[relative] = stream.read()
    if "Cargo.toml" not in result:
        raise RuntimeError("Registry archive has no package manifest")
    return dict(sorted(result.items()))


def _notices(files):
    selected = {
        name: data
        for name, data in files.items()
        if "/" not in name
        and name.lower().startswith(("license", "copying", "notice", "copyright"))
    }
    package = tomllib.loads(files["Cargo.toml"].decode())["package"]
    if name := package.get("license-file"):
        name = _relative(name).as_posix()
        if name not in files:
            raise RuntimeError("Upstream license-file is missing from its verified archive")
        selected[name] = files[name]
    if package["name"] == "libsqlite3-sys":
        comment = re.match(rb"\s*/\*.*?\*/", files.get("sqlite3/sqlite3.h", b""), re.S)
        if not comment or b"disclaims copyright" not in comment[0]:
            raise RuntimeError("Missing bundled SQLite upstream disclaimer")
        selected["sqlite3/NOTICE.txt"] = comment[0] + b"\n"
    if not selected or any(not data for data in selected.values()):
        raise RuntimeError("Missing upstream license notices")
    return dict(sorted(selected.items()))


class CargoDependencies:
    """Resolve the union of explicit targets' selected normal/build closures.

    No Cargo build, fetch, Git network command or credential helper is invoked.
    Resolution is fixed at construction; source validation/hashes are refreshed
    on every provenance() or retain_notices() call.
    """

    def __init__(self, root: Path, packages: Sequence[str], targets: Sequence[str], env: dict):
        self.root = Path(root).resolve()
        if isinstance(packages, str) or isinstance(targets, str) or not packages or not targets:
            raise ValueError("Select package names and at least one target")
        self.roots, self.targets = sorted(set(packages)), sorted(set(targets))
        self.env = {
            key: value
            for key, value in env.items()
            if not any(word in key.upper() for word in ("TOKEN", "PASSWORD", "SECRET"))
            and key not in ("SSH_AUTH_SOCK", "GIT_ASKPASS", "SSH_ASKPASS")
        }
        self.env.update(
            CARGO_NET_OFFLINE="true",
            GIT_TERMINAL_PROMPT="0",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
        )
        selected, workspace, features = {}, set(), {}
        for target in self.targets:
            metadata = json.loads(
                _command(
                    [
                        "cargo",
                        "metadata",
                        "--locked",
                        "--offline",
                        "--format-version",
                        "1",
                        "--filter-platform",
                        target,
                    ],
                    self.root,
                    self.env,
                    operation="Cargo metadata",
                )
            )
            if Path(metadata["workspace_root"]).resolve() != self.root:
                raise RuntimeError("Cargo resolved a different workspace root")
            descriptors = {p["id"]: p for p in metadata["packages"]}
            members = set(metadata["workspace_members"])
            nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
            pending, reached = [], set()
            for name in self.roots:
                roots = [
                    p["id"]
                    for p in descriptors.values()
                    if p["name"] == name and p["id"] in members
                ]
                if len(roots) != 1:
                    raise RuntimeError("Missing unambiguous selected workspace package: " + name)
                pending.extend(roots)
            while pending:
                identity = pending.pop()
                if identity in reached:
                    continue
                reached.add(identity)
                node, package = nodes[identity], descriptors[identity]
                if identity in selected and selected[identity] != package:
                    raise RuntimeError("Cargo package descriptor changed between targets")
                selected[identity] = package
                if identity in members:
                    workspace.add(identity)
                features.setdefault(identity, {})[target] = sorted(node.get("features", []))
                for dependency in node["deps"]:
                    if any(kind["kind"] in (None, "build") for kind in dependency["dep_kinds"]):
                        pending.append(dependency["pkg"])
        order = lambda p: (p["name"], p["version"], p.get("source") or "")
        self.packages = sorted(selected.values(), key=order)
        self.workspace_packages = [p for p in self.packages if p["id"] in workspace]
        self._workspace = workspace
        self._features = features

    def _lock(self, package):
        records = tomllib.loads(_read(self.root / "Cargo.lock").decode()).get("package", [])
        matches = [
            p
            for p in records
            if (p["name"], p["version"], p.get("source"))
            == (package["name"], package["version"], package.get("source"))
        ]
        if len(matches) != 1:
            raise RuntimeError("Selected dependency has no exact Cargo.lock identity")
        return matches[0]

    def _registry(self, package):
        record = self._lock(package)
        crate = Path(package["manifest_path"]).parent
        directory = package["name"] + "-" + package["version"]
        if crate.name != directory or crate.parent.parent.name != "src":
            raise RuntimeError("Registry dependency is not in its Cargo source cache")
        archive = crate.parents[2] / "cache" / crate.parent.name / (directory + ".crate")
        files = _archive(archive, directory, record.get("checksum", ""))
        cached = _files(crate, exclude={".cargo-checksum.json", ".cargo-ok"})
        if cached != files:
            raise RuntimeError("Registry source differs from its verified locked archive")
        manifest = tomllib.loads(files["Cargo.toml"].decode())["package"]
        if (manifest["name"], manifest["version"]) != (package["name"], package["version"]):
            raise RuntimeError("Registry archive package identity differs")
        return record, files

    def _git(self, package):
        self._lock(package)
        source = _source(package["source"])
        revision = urlsplit(source.partition("+")[2]).fragment
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            raise RuntimeError("Git dependency requires a full immutable commit SHA")
        crate = Path(package["manifest_path"]).parent
        run = lambda operation, *args: _command(
            ["git", *args], crate, self.env, operation=operation
        )
        repository = Path(
            run("Git repository root", "rev-parse", "--show-toplevel").decode().strip()
        ).resolve()
        if (
            not crate.is_relative_to(repository)
            or run("Git HEAD revision", "rev-parse", "HEAD").decode().strip() != revision
        ):
            raise RuntimeError("Git dependency differs from its locked revision")
        # Cargo writes one cache-completion marker outside the pinned Git tree.
        # It is not crate source; every other dirty/untracked path still fails.
        status = run(
            "Git worktree status", "status", "--porcelain=v1", "--untracked-files=all", "-z"
        ).split(b"\0")
        if any(entry and entry != b"?? .cargo-ok" for entry in status):
            raise RuntimeError("Git dependency must be clean, including untracked files")
        metadata = _build_metadata_files(package, repository)
        # The selected crate's source inventory and inherited manifests belong
        # to this dependency. Sibling SDKs, tests outside the crate and prebuilt
        # Artifacts are not compiler inputs of this dependency.
        actual = {
            (crate / name).relative_to(repository).as_posix(): data
            for name, data in _files(
                crate, exclude=_SKIP | ({".cargo-ok"} if crate == repository else set())
            ).items()
        }
        actual.update(metadata)
        prefix = PurePosixPath(crate.relative_to(repository).as_posix())
        tree = {}
        for entry in run("Git source tree", "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
            if not entry:
                continue
            header, name = entry.split(b"\t", 1)
            mode, kind, digest = header.decode().split()
            relative = _relative(name.decode()).as_posix()
            path = PurePosixPath(relative)
            inside = path.is_relative_to(prefix)
            if relative not in metadata and (
                not inside or any(part in _SKIP for part in path.relative_to(prefix).parts)
            ):
                continue
            if kind != "blob" or mode not in ("100644", "100755"):
                raise RuntimeError("Selected Git source contains unsupported links or submodules")
            data = _source_file(repository / relative, repository)
            if (
                hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
                != digest
            ):
                raise RuntimeError("Git source bytes differ from the pinned commit")
            tree[relative] = data
        for relative, data in actual.items():
            if relative not in tree or tree[relative] != data:
                raise RuntimeError("Git source includes uncommitted build inputs")
        return repository, tree

    def provenance(self):
        """Return {roots, targets, workspaceInputs, packages}; no local absolute paths."""
        workspace = {
            "Cargo.toml": _read(self.root / "Cargo.toml"),
            "Cargo.lock": _read(self.root / "Cargo.lock"),
        }
        for name in (
            "rust-toolchain.toml",
            "rust-toolchain",
            ".cargo/config",
            ".cargo/config.toml",
        ):
            if (self.root / name).exists() or (self.root / name).is_symlink():
                workspace[name] = _read(self.root / name)
        records = []
        for package in self.packages:
            source = package.get("source")
            record = {
                "name": package["name"],
                "version": package["version"],
                "features": self._features[package["id"]],
            }
            if package["id"] in self._workspace:
                self._lock(package)
                crate = Path(package["manifest_path"]).parent
                if not crate.resolve().is_relative_to(self.root) or source is not None:
                    raise RuntimeError("Workspace package escapes the selected root")
                files = _build_metadata_files(package, self.root)
                workspace.update(
                    {
                        name: data
                        for name, data in files.items()
                        if PurePosixPath(name).name == "Cargo.toml"
                    }
                )
                record.update(source="workspace", inputs=_hashes(files))
            elif source and source.startswith(("registry+", "sparse+")):
                _source(source)
                locked, files = self._registry(package)
                record.update(source=source, checksum=locked["checksum"], inputs=_hashes(files))
            elif source and source.startswith("git+"):
                _, files = self._git(package)
                record.update(source=source, inputs=_hashes(files))
            else:
                raise RuntimeError("External path patches are not immutable dependencies")
            records.append(record)
        return {
            "roots": self.roots,
            "targets": self.targets,
            "workspaceInputs": _hashes(workspace),
            "packages": records,
        }

    def configure_remaps(self, env):
        """Keep caller flags and append stable root/compiler/dependency remaps."""
        self.provenance()  # Never bless an edited dependency while configuring it.
        # Cargo splits plain RUSTFLAGS on whitespace, without shell unquoting.
        # An explicitly present encoded value, including empty, takes priority.
        flags = (
            env["CARGO_ENCODED_RUSTFLAGS"].split("\x1f")
            if env.get("CARGO_ENCODED_RUSTFLAGS")
            else ([] if "CARGO_ENCODED_RUSTFLAGS" in env else env.get("RUSTFLAGS", "").split())
        )
        sysroot = Path(
            _command(
                ["rustc", "--print", "sysroot"],
                self.root,
                self.env,
                operation="Rust compiler sysroot",
            )
            .decode()
            .strip()
        )
        if not sysroot.is_absolute() or not sysroot.is_dir():
            raise RuntimeError("Compiler did not report an installed absolute sysroot")
        remaps = {(self.root, "/workspace"), (sysroot, "/rust-toolchain")}
        for package in self.packages:
            source = package.get("source") or ""
            if source.startswith(("registry+", "sparse+")):
                remaps.add(
                    (
                        Path(package["manifest_path"]).parent,
                        "/cargo/registry/" + package["name"] + "-" + package["version"],
                    )
                )
            elif source.startswith("git+"):
                repository, _ = self._git(package)
                remaps.add((repository, "/cargo/git/" + source.rsplit("#", 1)[1]))
        for path, label in sorted(
            remaps, key=lambda item: (len(str(item[0])), str(item[0]), item[1])
        ):
            flag = "--remap-path-prefix=" + str(path) + "=" + label
            if flag not in flags:
                flags.append(flag)
        env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(flags)

    def _legacy_notices(self, record):
        """Old SDK manifests recorded archive identity but no notice file hashes."""
        roots = {
            Path(p["manifest_path"]).parent.parents[2]
            for p in self.packages
            if (p.get("source") or "").startswith(("registry+", "sparse+"))
        }
        cargo_home = Path(
            self.env.get("CARGO_HOME", Path(self.env.get("HOME", Path.home())) / ".cargo")
        )
        roots.add(cargo_home / "registry")
        for root in sorted(roots):
            for archive in sorted((root / "cache").glob("*/" + record["directory"] + ".crate")):
                if _hash(_read(archive)) == record["checksum"]:
                    return _notices(_archive(archive, record["directory"], record["checksum"]))
        raise RuntimeError(
            "Cannot verify legacy generated notice ownership without its exact cached archive"
        )

    def registry_notices(self):
        """Read verified notices without mutating the SDK or source caches.

        Return directory -> {source, checksum, files}, with relative file names
        and original bytes. Only the selected normal/build target graph is read.
        """
        result = {}
        for package in self.packages:
            if not (package.get("source") or "").startswith(("registry+", "sparse+")):
                continue
            _source(package["source"])
            locked, files = self._registry(package)
            name = package["name"] + "-" + package["version"]
            if not _GENERATED.fullmatch(name):
                raise RuntimeError("Invalid generated registry notice directory")
            if name in result:
                raise RuntimeError("Registry notice directory has conflicting package sources")
            result[name] = {
                "source": package["source"],
                "checksum": locked["checksum"],
                "files": _notices(files),
            }
        return dict(sorted(result.items()))

    def retain_notices(self, *, notice_directory="ThirdParty"):
        """Retain verified registry licenses only; preserve all manual/Rust notices.

        Return the sorted registry ownership records with a UTF-8/LF index on all
        hosts; upstream notice bytes are never normalized. Existing generated material
        must still match its recorded file hashes (or its verified legacy archive)
        before any replacement or prune. Publication rolls back individual owned
        directories on failure; ThirdParty itself is never replaced.
        """
        selected = self.registry_notices()
        notices = {name: record["files"] for name, record in selected.items()}
        current = [
            {
                "directory": name,
                "source": record["source"],
                "checksum": record["checksum"],
                "files": _hashes(record["files"]),
            }
            for name, record in selected.items()
        ]
        third_party = notice_root(self.root, notice_directory)
        manifest = third_party / "registry-notices.json"
        previous = json.loads(_read(manifest)) if manifest.exists() or manifest.is_symlink() else []
        if not isinstance(previous, list):
            raise RuntimeError("Invalid registry notice ownership manifest")
        owned = set()
        for record in previous:
            if not isinstance(record, dict):
                raise RuntimeError("Invalid generated notice ownership record")
            name = record.get("directory", "")
            if (
                not _GENERATED.fullmatch(name)
                or name in owned
                or not _SHA256.fullmatch(record.get("checksum", ""))
            ):
                raise RuntimeError("Invalid generated notice directory or checksum")
            if not record.get("source", "").startswith(("registry+", "sparse+")):
                raise RuntimeError("Invalid generated notice source")
            _source(record["source"])
            owned.add(name)
            path = third_party / name
            if not path.exists() and not path.is_symlink():
                continue
            actual = _files(path)
            expected = record.get("files")
            if expected is None:
                expected = _hashes(self._legacy_notices(record))
            if (
                not isinstance(expected, dict)
                or not expected
                or any(
                    not isinstance(value, str) or not _SHA256.fullmatch(value)
                    for value in expected.values()
                )
                or any(
                    not isinstance(key, str) or _relative(key).as_posix() != key for key in expected
                )
                or _hashes(actual) != expected
            ):
                raise RuntimeError("Generated notice ownership changed; preserving existing files")
            allowed_dirs = {
                parent.as_posix()
                for key in expected
                for parent in PurePosixPath(key).parents
                if str(parent) != "."
            }
            if any(
                p.relative_to(path).as_posix() not in allowed_dirs
                for p in path.rglob("*")
                if p.is_dir()
            ):
                raise RuntimeError("Generated notice directory contains unowned directories")
        for name in notices:
            if (
                (third_party / name).exists() or (third_party / name).is_symlink()
            ) and name not in owned:
                raise RuntimeError("Refusing to replace manual upstream notices")
        third_party.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".cargo-notices-", dir=third_party))
        recovery_required = False
        try:
            for name, files in notices.items():
                for relative, data in files.items():
                    output = stage / "new" / name / relative
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(data)
            staged_manifest = stage / "registry-notices.json"
            staged_manifest.write_bytes(
                (json.dumps(current, indent=2, sort_keys=True) + "\n").encode("utf-8")
            )
            backups, installed = [], []
            try:
                for name in sorted(owned | set(notices)):
                    destination = third_party / name
                    if destination.exists():
                        backup = stage / "previous" / name
                        backup.parent.mkdir(parents=True, exist_ok=True)
                        backups.append((backup, destination))
                        os.replace(destination, backup)
                    if name in notices:
                        staged = stage / "new" / name
                        installed.append((staged, destination))
                        os.replace(staged, destination)
                os.replace(staged_manifest, manifest)
            except BaseException:
                # A signal can arrive after rename succeeds but before Python
                # returns from it. The index rename commits the complete tree.
                if not staged_manifest.exists():
                    raise
                try:
                    for staged, destination in reversed(installed):
                        if not staged.exists():
                            shutil.rmtree(destination)
                    for backup, destination in reversed(backups):
                        if backup.exists():
                            os.replace(backup, destination)
                except BaseException as rollback_error:
                    recovery_required = True
                    raise RuntimeError(
                        f"Notice rollback incomplete; retained recovery directory: {stage}"
                    ) from rollback_error
                raise
        finally:
            if not recovery_required:
                shutil.rmtree(stage)
        return current


def _runtime_pin(root):
    pinned = tomllib.loads(_read(root / "rust-toolchain.toml").decode())["toolchain"]["channel"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pinned):
        raise RuntimeError("Rust runtime retention requires an exact pinned release version")
    return pinned


def _runtime_destination(root, notice_directory):
    destination = notice_root(root, notice_directory) / "Rust"
    if destination.is_symlink():
        raise RuntimeError("Rust runtime notice directory must not be a symlink")
    return destination


def runtime_notices(root: Path, env: dict, *, notice_directory="ThirdParty"):
    """Validate retained files/version only; no compiler, docs, source or network.

    Existing legacy provenance is accepted if its version and all four byte/hash
    records match. This does not claim that an upstream source was revalidated.
    Provision missing notices explicitly with retain_runtime_notices().
    """
    root = Path(root)
    pinned = _runtime_pin(root)
    destination = _runtime_destination(root, notice_directory)
    if not (destination / "provenance.json").exists():
        raise RuntimeError(
            "Missing retained Rust provenance.json; invoke retain_runtime_notices explicitly"
        )
    manifest = json.loads(_read(destination / "provenance.json"))
    if manifest.get("version") != pinned or set(manifest.get("files", {})) != set(_RUNTIME):
        raise RuntimeError("Retained Rust runtime provenance differs from the pinned compiler")
    files = {}
    for name in _RUNTIME:
        data = _read(destination / name)
        record = {"bytes": len(data), "sha256": _hash(data)}
        if not data or manifest["files"][name] != record:
            raise RuntimeError("Rust runtime notice differs from retained provenance")
        files[name] = record
    return {"version": pinned, "files": files}


def _runtime_source(source, pinned, env, sdk_root):
    """Read one explicitly selected public source, never another SDK's copy."""
    if source is not None:
        base = Path(source)
        if base.name.lower() == "rust" and base.parent.name.lower() == "thirdparty":
            raise RuntimeError("Another SDK's retained Rust notices are not an upstream source")
        if base.is_symlink() or not base.is_dir():
            raise RuntimeError("Explicit Rust notice source must be a real directory")
        manifest_path = base / "provenance.json"
        if manifest_path.exists() or manifest_path.is_symlink():
            raw = _read(manifest_path)
            manifest = json.loads(raw)
            origin = manifest.get("provenance", {})
            if manifest.get("version") != pinned:
                raise RuntimeError("Explicit Rust notice source version differs from the SDK pin")
            if (
                origin.get("repository")
                not in (
                    "rust-lang/rust",
                    "https://github.com/rust-lang/rust",
                    "https://github.com/rust-lang/rust.git",
                )
                or not re.fullmatch(r"[a-f0-9]{40}", origin.get("revision", ""))
                or set(manifest.get("files", {})) != set(_RUNTIME)
            ):
                raise RuntimeError(
                    "Explicit Rust notice source lacks public Rust revision/hash provenance"
                )
            proof = {
                "kind": "public-source-manifest",
                "repository": "https://github.com/rust-lang/rust",
                "revision": origin["revision"],
                "sourceManifestSHA256": _hash(raw),
            }
            if "sourceArchiveURL" in origin or "sourceArchiveSHA256" in origin:
                url = urlsplit(origin.get("sourceArchiveURL", ""))
                checksum = origin.get("sourceArchiveSHA256", "")
                if (
                    url.scheme != "https"
                    or url.netloc != "static.rust-lang.org"
                    or url.query
                    or url.fragment
                    or not url.path.startswith("/dist/")
                    or pinned not in url.path
                    or not _SHA256.fullmatch(checksum)
                ):
                    raise RuntimeError(
                        "Explicit Rust archive provenance differs from the pinned public source"
                    )
                proof.update(
                    sourceArchiveURL=origin["sourceArchiveURL"], sourceArchiveSHA256=checksum
                )
            files = {}
            for name in _RUNTIME:
                record = manifest["files"][name]
                relative = _relative(record.get("path", name)).as_posix()
                path = base / relative
                # Resolve directory links too; even an explicit manifest cannot
                # borrow notice bytes from outside its selected source tree.
                if not path.resolve().is_relative_to(base.resolve()):
                    raise RuntimeError("Rust source notice path escapes its selected tree")
                data = _read(path)
                if (
                    not data
                    or record.get("bytes") != len(data)
                    or record.get("sha256") != _hash(data)
                ):
                    raise RuntimeError("Rust source notice differs from its explicit provenance")
                files[name] = data
            return files, proof

        # Public Rust release source/distribution trees carry their own version
        # and full commit stamp. No Git checkout operation or network is needed.
        stamp = base / "version" if (base / "version").exists() else base / "src/version"
        stamp_bytes = _read(stamp)
        version = stamp_bytes.decode().strip().split()
        if not version or version[0] != pinned:
            raise RuntimeError("Explicit Rust source tree version differs from the SDK pin")
        revision = _read(base / "git-commit-hash").decode().strip()
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            raise RuntimeError("Rust source tree requires its full release commit stamp")
        proof = {
            "kind": "public-release-tree",
            "repository": "https://github.com/rust-lang/rust",
            "revision": revision,
            "versionFile": stamp.relative_to(base).as_posix(),
            "versionFileSHA256": _hash(stamp_bytes),
        }
        docs = base / "share/doc/rust"
    else:
        inspection = {
            key: value
            for key, value in env.items()
            if not any(word in key.upper() for word in ("TOKEN", "PASSWORD", "SECRET"))
        }
        inspection.update(RUSTUP_AUTO_INSTALL="0", CARGO_NET_OFFLINE="true")
        compiler = env.get("RUSTC", "rustc")
        output = _command(
            [compiler, "--version", "--verbose"],
            sdk_root,
            inspection,
            operation="Rust compiler version",
        ).decode()
        fields = dict(line.split(": ", 1) for line in output.splitlines() if ": " in line)
        if (
            not output.startswith("rustc " + pinned + " ")
            or fields.get("release") != pinned
            or not re.fullmatch(r"[a-f0-9]{40}", fields.get("commit-hash", ""))
        ):
            raise RuntimeError(
                "Selected installed Rust compiler differs from the SDK's pinned release"
            )
        base = Path(
            _command(
                [compiler, "--print", "sysroot"],
                sdk_root,
                inspection,
                operation="Rust compiler sysroot",
            )
            .decode()
            .strip()
        )
        if not base.is_absolute() or not base.is_dir():
            raise RuntimeError("Selected Rust compiler did not report an installed sysroot")
        docs = base / "share/doc/rust"
        proof = {
            "kind": "installed-compiler-docs",
            "repository": "https://github.com/rust-lang/rust",
            "revision": fields["commit-hash"],
            "release": fields["release"],
        }
        channel = base / "lib/rustlib/multirust-channel-manifest.toml"
        if channel.exists():
            raw = _read(channel)
            manifest = tomllib.loads(raw.decode())
            release = manifest.get("pkg", {}).get("rustc", {}).get("version", "")
            match = re.fullmatch(re.escape(pinned) + r" \(([a-f0-9]{7,40}) [0-9-]+\)", release)
            if not match or not fields["commit-hash"].startswith(match[1]):
                raise RuntimeError(
                    "Installed Rust component manifest differs from the compiler pin"
                )
            proof["sourceToolchainManifestSHA256"] = _hash(raw)

    files, paths = {}, {}
    for name in _RUNTIME:
        path = base / name if source is not None and (base / name).exists() else docs / name
        if not path.is_file():
            raise RuntimeError(
                "Pinned Rust notice source is incomplete ("
                + name
                + "); supply an explicit verified public source; no download or SDK fallback is performed"
            )
        if not path.resolve().is_relative_to(base.resolve()):
            raise RuntimeError("Rust source notice path escapes its selected tree")
        data = _read(path)
        if not data:
            raise RuntimeError("Pinned Rust source contains an empty notice: " + name)
        files[name] = data
        paths[name] = path.relative_to(base).as_posix()
    proof["sourceFiles"] = paths
    return files, proof


def retain_runtime_notices(root: Path, env: dict, source=None, *, notice_directory="ThirdParty"):
    """Explicit maintainer retention; normal builds must call runtime_notices().

    Source precedence: explicit Path, SDK_TOOLING_RUST_NOTICE_SOURCE, then the
    selected pinned rustc's share/doc/rust. Explicit trees require version (or
    src/version), git-commit-hash and all four static notices, or provenance.json
    with version, public Rust repository/revision and per-file bytes/sha256
    (optional relative path). The caller supplies public, preverified material;
    this helper never downloads or generates missing notices.

    Valid retained manifests need no installed compiler/docs when no source was
    requested. Explicit sources are still checked against retained bytes and
    never silently upgrade or overwrite different existing notices. Return the
    new manifest, or retained-file proof without claiming source revalidation.
    """
    root = Path(root).resolve()
    pinned = _runtime_pin(root)
    destination = _runtime_destination(root, notice_directory)
    manifest_path = destination / "provenance.json"
    supplied = source if source is not None else env.get("SDK_TOOLING_RUST_NOTICE_SOURCE")
    retained = None
    if manifest_path.exists() or manifest_path.is_symlink():
        retained = runtime_notices(root, env, notice_directory=notice_directory)
        retained["provenance"] = {
            "kind": "retained-manifest",
            "manifestSHA256": _hash(_read(manifest_path)),
        }
        if supplied is None:
            return retained
    files, proof = _runtime_source(supplied, pinned, env, root)
    records = {name: {"bytes": len(data), "sha256": _hash(data)} for name, data in files.items()}
    if retained is not None:
        if records != retained["files"]:
            raise RuntimeError(
                "Explicit Rust source differs from already retained notice hashes; no upgrade performed"
            )
        return retained

    # Legacy SDKs may have original notices but no manifest. Adopt only equal
    # bytes, preserve unrelated/manual files and never replace the Rust tree.
    if destination.exists():
        _files(destination)
    for name, data in files.items():
        path = destination / name
        if (path.exists() or path.is_symlink()) and _read(path) != data:
            raise RuntimeError(
                "Existing Rust notice differs from selected pinned source; preserving originals"
            )
    manifest = {
        "schemaVersion": 1,
        "component": "Rust runtime and standard library",
        "version": pinned,
        "provenance": proof,
        "files": records,
    }
    third_party = destination.parent
    third_party.mkdir(parents=True, exist_ok=True)
    created_directory = not destination.exists()
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rust-notices-", dir=third_party) as temporary:
        stage, published = Path(temporary), []
        payload = {
            **files,
            "provenance.json": (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
        }
        try:
            for name, data in payload.items():
                staged, target = stage / name, destination / name
                staged.write_bytes(data)
                if target.exists() and name != "provenance.json":
                    if _read(target) != data:
                        raise RuntimeError("Rust notices changed during retention")
                    continue
                published.append((staged, target))
                os.link(staged, target)  # Exclusive atomic creation, no overwrites.
        except BaseException:
            for staged, target in reversed(published):
                try:
                    linked = os.path.samestat(target.lstat(), staged.stat())
                except FileNotFoundError:
                    continue
                if not linked:
                    continue
                # A signal may arrive after link succeeds. Provenance is linked
                # last and commits the complete set, even if the call did not return.
                if target == manifest_path:
                    break
                target.unlink()
            if created_directory and not any(destination.iterdir()):
                destination.rmdir()
            raise
    runtime_notices(root, env, notice_directory=notice_directory)
    return manifest
