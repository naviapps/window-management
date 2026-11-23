"""Run independent SDK Git/Rust and installed macOS C fixtures."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
from contextlib import nullcontext
from pathlib import Path

from . import windows
from .artifacts import files, hashes

_REPOSITORY_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git")
_REVISION = re.compile(r"[a-f0-9]{40}")
_PUBLIC_REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
_C_FIXTURE = "fixtures/c-consumer/main.c"
_C_RECEIPT = "Artifacts/native-build.json"


def _run(command, *, cwd, env):
    try:
        return subprocess.run(command, cwd=cwd, env=env, check=True, text=True, capture_output=True)
    except subprocess.CalledProcessError as error:
        print(error.stdout or "", end="", file=sys.stderr)
        print(error.stderr or "", end="", file=sys.stderr)
        raise


def _git(root, *arguments, env=None):
    if env is None:
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    return _run(
        ["git", "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false", *arguments],
        cwd=root,
        env=dict(env, GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1"),
    ).stdout.strip()


def _source_revision(root, requested):
    revision, tree = _git(root, "rev-parse", "HEAD", "HEAD^{tree}").splitlines()
    if not re.fullmatch(r"[a-f0-9]{40}", requested if requested is not None else revision):
        raise ValueError("Provide a full 40-character SDK commit ID")
    if requested is not None and requested != revision:
        raise ValueError("The producer source HEAD must equal the requested SDK revision")
    if _git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("The producer source must be a clean committed SDK tree")
    return revision, tree


def _environment(work, *, rust=False, windows_architecture=None):
    allowed = {"HOME", "CFFIXED_USER_HOME", "DEVELOPER_DIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"}
    if rust:
        allowed.update(
            {
                "PATH",
                "RUSTUP_HOME",
                "HTTPS_PROXY",
                "HTTP_PROXY",
                "NO_PROXY",
                "SYSTEMROOT",
                "WINDIR",
                "PATHEXT",
                "COMSPEC",
            }
        )
    if windows_architecture:
        allowed.update(
            {
                "ALLUSERSPROFILE",
                "APPDATA",
                "LOCALAPPDATA",
                "PROCESSOR_ARCHITECTURE",
                "PROCESSOR_ARCHITEW6432",
                "PROGRAMDATA",
                "PROGRAMFILES",
                "PROGRAMFILES(X86)",
                "PROGRAMW6432",
                "SYSTEMDRIVE",
                "USERPROFILE",
            }
        )
        env = {key.upper(): value for key, value in os.environ.items() if key.upper() in allowed}
    else:
        env = {key: value for key, value in os.environ.items() if key in allowed}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    for key, name in {
        "TMPDIR": "tmp",
        "XDG_CONFIG_HOME": "config",
        "XDG_CACHE_HOME": "cache",
    }.items():
        path = work / name
        path.mkdir()
        env[key] = str(path)
    if os.name == "nt" or windows_architecture:
        env.update(TEMP=env["TMPDIR"], TMP=env["TMPDIR"])
    if rust:
        config = work / "gitconfig"
        config.write_text("", encoding="utf-8")
        env.update(
            GIT_CONFIG_GLOBAL=str(config),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            GIT_ALLOW_PROTOCOL="file",
            GIT_NO_REPLACE_OBJECTS="1",
            GIT_NO_LAZY_FETCH="1",
        )
    return env


def _prepare_git_delivery(source, work, env, git_url, revision, tree, *, name="sdk.git"):
    source = Path(source).resolve(strict=True)
    if not (source.is_dir() or source.is_file()):
        raise ValueError("Git delivery requires a local repository or bundle")
    if source.is_dir() and _git(source, "rev-parse", "--is-shallow-repository", env=env) == "true":
        raise ValueError("A shallow Git source needs a complete local mirror or bundle")
    mirror = work / name
    _git(work, "clone", "--bare", "--no-local", "--", str(source), str(mirror), env=env)
    if _git(mirror, "rev-parse", "--is-shallow-repository", env=env) != "false":
        raise ValueError("The local Git delivery must contain complete history")
    _git(mirror, "fsck", "--full", "--no-reflogs", env=env)
    delivered = _git(mirror, "rev-parse", revision + "^{commit}", revision + "^{tree}", env=env)
    actual_revision, actual_tree = delivered.splitlines()
    if actual_revision != revision or (tree is not None and actual_tree != tree):
        raise ValueError("The local Git delivery differs from the clean producer commit/tree")
    with Path(env["GIT_CONFIG_GLOBAL"]).open("a", encoding="utf-8") as configuration:
        configuration.write(f'[url "{mirror.as_uri()}"]\n  insteadOf = {git_url}\n')
    return mirror


def _repository(url):
    match = _REPOSITORY_URL.fullmatch(url) if isinstance(url, str) else None
    if not match or any(part in {".", ".."} for part in match[1].split("/")):
        raise ValueError("The Rust Git dependency needs a canonical GitHub repository URL")
    return match[1]


def _extra_dependencies(spec, git_url, packages):
    if spec is None:
        return {}
    if not isinstance(spec, dict):
        raise ValueError("Specify additional SDK Git dependencies by package name")
    repositories = {}
    for name, pin in spec.items():
        if (
            not isinstance(name, str)
            or not re.fullmatch(r"[A-Za-z0-9_-]+", name)
            or name in packages
            or not isinstance(pin, dict)
            or set(pin) != {"git", "rev"}
            or not isinstance(pin["rev"], str)
            or not _REVISION.fullmatch(pin["rev"])
        ):
            raise ValueError(
                "The additional SDK Git dependency needs a unique package and full revision"
            )
        repository = _repository(pin["git"]).casefold()
        if repository == _repository(git_url).casefold():
            raise ValueError("The additional SDK Git dependency duplicates the producer repository")
        if repositories.setdefault(repository, pin) != pin:
            raise ValueError("Each additional SDK Git repository needs one exact URL and revision")
    return spec


def _dependency_pins(dependencies):
    return {_repository(pin["git"]): pin for pin in dependencies.values()}


def _local_dependency_sources(arguments, repositories):
    if len(repositories) == len(arguments) == 1:
        repository = next(iter(repositories))
        argument = arguments[0]
        if not argument.startswith(repository + "="):
            return {repository: Path(argument)}
    sources = {}
    for argument in arguments:
        repository, separator, path = argument.partition("=")
        if not separator or not path or repository not in repositories or repository in sources:
            raise ValueError("Supply each SDK Git source once as OWNER/REPO=PATH")
        sources[repository] = Path(path)
    if sources.keys() != repositories.keys():
        raise ValueError("Supply each SDK Git source once as OWNER/REPO=PATH")
    return sources


def _registry_dependencies(spec, git_packages):
    if spec is None:
        return {}
    if not isinstance(spec, dict) or len(spec) > 1:
        raise ValueError("Specify at most one pinned public registry dependency")
    for name, pin in spec.items():
        if (
            not isinstance(name, str)
            or not re.fullmatch(r"[A-Za-z0-9_-]+", name)
            or name in git_packages
            or not isinstance(pin, dict)
            or set(pin) != {"version", "features"}
            or not isinstance(pin["version"], str)
            or not re.fullmatch(r"=[0-9]+\.[0-9]+\.[0-9]+", pin["version"])
            or not isinstance(pin["features"], list)
            or any(
                not isinstance(feature, str) or not re.fullmatch(r"[A-Za-z0-9_+.-]+", feature)
                for feature in pin["features"]
            )
            or len(set(pin["features"])) != len(pin["features"])
        ):
            raise ValueError(
                "The public registry dependency needs an exact version and explicit features"
            )
    return spec


def _unique_members(pairs):
    row = dict(pairs)
    if len(row) != len(pairs):
        raise ValueError("Duplicate key in CI source manifest")
    return row


def _ci_dependency_bundles(pins, verifier):
    source = os.environ.get("NAVI_CI_SOURCES")
    if not source:
        raise ValueError(
            "Supply the additional SDK Git bundles through CI or --git-dependency-source"
        )
    manifest = Path(source)
    if not manifest.is_absolute() or manifest.is_symlink() or not manifest.is_file():
        raise ValueError("The CI source manifest must be an ordinary absolute file")
    rows = json.loads(manifest.read_text(encoding="utf-8"), object_pairs_hook=_unique_members)
    if not isinstance(rows, list):
        raise ValueError("The CI source manifest must be a list of source bundles")
    return {
        repository: _ci_dependency_bundle(manifest, rows, repository, pin, verifier)
        for repository, pin in pins.items()
    }


def _ci_dependency_bundle(manifest, rows, repository, pin, verifier):
    def field(value):
        # The expected identities and generated members are ASCII and nonempty.
        # Invalid strings cannot match them; keep their rows in the manifest order.
        if not isinstance(value, str) or "\0" in value:
            return ""
        return value.encode("utf-8", "backslashreplace").decode("utf-8")

    url = pin["git"]
    fields = [repository, repository.casefold(), url, url.casefold(), pin["rev"]]
    for row in rows:
        row = row if isinstance(row, dict) else {}
        repo, location, revision, bundle = map(
            field, (row.get(key) for key in ("repository", "url", "revision", "bundle"))
        )
        fields.extend((repo, repo.casefold(), location, location.casefold(), revision, bundle))
    response = verifier("select-ci-bundle", fields, selects=True)
    if not re.fullmatch(r"[0-9]+", response) or (index := int(response)) >= len(rows):
        raise ValueError("Unexpected additional SDK Git bundle selection")
    member = f"{index}.bundle"
    bundle = manifest.parent / member
    if bundle.is_symlink() or not bundle.is_file():
        raise ValueError("The additional SDK Git bundle must be an ordinary manifest member")
    checksum = rows[index].get("sha256")
    if not isinstance(checksum, str) or not re.fullmatch(r"[a-f0-9]{64}", checksum):
        raise ValueError("Invalid additional SDK Git bundle checksum")
    return bundle, checksum


def _rust_manifest(
    template,
    git_url,
    packages,
    revision,
    *,
    dependencies=None,
    optional=(),
    registry_dependencies=None,
):
    if template.count("@SDK_REVISION@") != len(packages):
        raise ValueError("The Rust fixture must parameterize each SDK dependency")
    text = template.replace("@SDK_REVISION@", revision)
    manifest = tomllib.loads(text)
    if "workspace" not in manifest or manifest.get("dependencies") != {
        **{
            name: {
                "git": git_url,
                "rev": revision,
                **({"optional": True} if name in optional else {}),
            }
            for name in packages
        },
        **(dependencies or {}),
        **(registry_dependencies or {}),
    }:
        raise ValueError(
            "The Rust fixture needs its own workspace and the exact public Git packages and registry pins"
        )
    return text


def _git_identity(url, revision):
    return f"git+{url}?rev={revision}#{revision}"


def _prepare_identity_verifier(work, rustc, env, target=None, *, compiler_verified=False):
    """Compile the immutable tooling source before creating the client's Cargo home."""
    if not compiler_verified:
        version = _run([rustc, "-vV"], cwd=work, env=env).stdout.splitlines()
        if f"release: {env['RUSTUP_TOOLCHAIN']}" not in version:
            raise ValueError("The prepared Rust compiler differs from the SDK pin")
    source = Path(__file__).resolve().parents[1] / "tools/consumer-identity/src/main.rs"
    if not source.is_file() or source.is_symlink():
        raise ValueError("Missing ordinary installed-consumer verifier source")
    material = source.read_bytes()
    snapshot = work / "consumer-identity.rs"
    with snapshot.open("xb") as stream:
        stream.write(material)
    executable = work / ("consumer-identity.exe" if os.name == "nt" else "consumer-identity")
    _run(
        [
            rustc,
            "--edition=2024",
            "--crate-name",
            "sdk_consumer_identity",
            *(["--target", target, "-Ctarget-feature=+crt-static"] if target else []),
            "-o",
            str(executable),
            str(snapshot),
        ],
        cwd=work,
        env=env,
    )
    if source.read_bytes() != material or snapshot.read_bytes() != material:
        raise ValueError("The installed-consumer verifier source changed during compilation")
    if target:
        architecture = next(key for key, value in windows.MSVC_TARGETS.items() if value == target)
        windows.require_pe_machine(executable, architecture)

    def request(operation, fields, *, selects=False):
        if any("\0" in field for field in fields):
            raise ValueError("Invalid Cargo package evidence record")
        try:
            result = subprocess.run(
                [str(executable), operation],
                cwd=work,
                env=env,
                input="\0".join(fields).encode("utf-8"),
                capture_output=True,
                check=False,
                timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise ValueError("Cannot run the installed-consumer identity verifier") from None
        # The verifier reserves exit code 2 for its validated policy diagnostics.
        if result.returncode == 2 and result.stderr and not result.stdout:
            raise ValueError(
                result.stderr.decode("utf-8", errors="replace").strip()
                or "Cargo package evidence verification failed"
            )
        if (
            result.returncode
            or result.stderr
            or bool(result.stdout) != selects
            or b"\0" in result.stdout
        ):
            raise ValueError("Unexpected response from the installed-consumer identity verifier")
        try:
            return result.stdout.decode("utf-8")
        except UnicodeDecodeError:
            raise ValueError(
                "Unexpected response from the installed-consumer identity verifier"
            ) from None

    return request


def _verify_packages(
    verifier, entries, packages, expected, label, *, dependencies=None, optional=(), registry=None
):
    records = [
        (
            "git",
            name,
            source,
            "optional" if name in optional and name not in (dependencies or {}) else "",
        )
        for name, source in (dict.fromkeys(packages, expected) | (dependencies or {})).items()
    ]
    records += [
        ("registry", name, _PUBLIC_REGISTRY, pin["version"][1:])
        for name, pin in (registry or {}).items()
    ]
    records += [
        ("package", entry["name"], entry.get("source") or "", entry.get("version") or "")
        for entry in entries
    ]
    verifier(label, [field for row in records for field in row])


def _check_rust_metadata(
    metadata,
    client,
    cargo_home,
    verifier,
    packages,
    expected,
    *,
    dependencies=None,
    optional=(),
    registry_dependencies=None,
):
    _verify_packages(
        verifier,
        metadata["packages"],
        packages,
        expected,
        "Cargo metadata",
        dependencies=dependencies,
        optional=optional,
        registry=registry_dependencies,
    )
    for package in metadata["packages"]:
        path = Path(package["manifest_path"]).resolve(strict=True)
        if not (path.is_relative_to(client) or path.is_relative_to(cargo_home)):
            raise ValueError("A Rust dependency escaped the fresh client/cache tree")


def _run_windows_rust_client(
    run, command, *, cwd, env, metadata, architecture, runtime_dir, verifier
):
    root = metadata["resolve"]["root"]
    package = next(package for package in metadata["packages"] if package.get("id") == root)
    binaries = [target["name"] for target in package["targets"] if "bin" in target["kind"]]
    binary = verifier("select-binary", [package.get("default_run") or "", *binaries], selects=True)

    result = run(
        [*command, "--bin", binary, "--message-format=json-render-diagnostics"], cwd=cwd, env=env
    )
    fields = [root, binary]
    for line in result.stdout.splitlines():
        if (
            line.startswith("{")
            and (message := json.loads(line)).get("reason") == "compiler-artifact"
        ):
            target = message["target"]
            fields.extend(
                (
                    message["package_id"],
                    target["name"],
                    "bin" if "bin" in target["kind"] else "",
                    message.get("executable") or "",
                )
            )
    executable = Path(verifier("select-executable", fields, selects=True))
    output = (Path(env["CARGO_TARGET_DIR"]) / windows.MSVC_TARGETS[architecture]).resolve()
    if (
        not executable.is_absolute()
        or executable.suffix.lower() != ".exe"
        or executable.is_symlink()
        or not executable.is_file()
        or not executable.resolve().is_relative_to(output)
    ):
        raise ValueError("The Windows Rust fixture must be inside the fresh target directory")
    windows.require_pe_machine(executable, architecture)
    return run([str(executable), str(runtime_dir)], cwd=cwd, env=env).stdout


def _run_rust(
    root,
    work,
    git_url,
    packages,
    revision,
    tree,
    delivery,
    resolved,
    runner=None,
    *,
    dependencies=None,
    dependency_sources=None,
    modes=None,
    mode_completed=None,
    registry_dependencies=None,
    windows_architecture=None,
):
    run = runner or _run
    env = _environment(work, rust=True, windows_architecture=windows_architecture)
    windows_host = None
    rustc = "rustc"
    if windows_architecture:
        windows_host = windows.host_architecture()
        if windows_host != windows_architecture and (windows_host, windows_architecture) != (
            "arm64",
            "x64",
        ):
            raise ValueError("Select the native Windows Rust target or x64 on ARM64")
        env, _ = windows.native_msvc_environment(
            windows_host, environment=env, target_architecture=windows_architecture
        )
        rustc = shutil.which(rustc, path=env["PATH"])
        if not rustc:
            raise ValueError("Select the SDK's Rust compiler before running the Rust consumer")
        rustc = str(Path(rustc).absolute())
        env["RUSTC"] = rustc
    env["RUSTUP_TOOLCHAIN"] = tomllib.loads(
        (root / "rust-toolchain.toml").read_text(encoding="utf-8")
    )["toolchain"]["channel"]
    cargo = shutil.which("cargo", path=env["PATH"])
    if not cargo:
        raise ValueError("Select the SDK's Rust toolchain before running the Rust consumer")
    host_target = None
    target = windows.MSVC_TARGETS.get(windows_architecture)
    if modes or target:
        env["RUSTUP_AUTO_INSTALL"] = "0"
        version = run([rustc, "-vV"], cwd=work, env=env).stdout.splitlines()
        if f"release: {env['RUSTUP_TOOLCHAIN']}" not in version:
            raise ValueError("The prepared Rust compiler differs from the SDK pin")
        host_target = next(
            (line.removeprefix("host: ") for line in version if line.startswith("host: ")), None
        )
        if not host_target or (target and host_target != windows.MSVC_TARGETS[windows_host]):
            raise ValueError("The Rust compiler host must match the native Windows host")
    if target and target != host_target:
        windows.require_rust_target_stdlib(
            run(
                [rustc, "--print", "target-libdir", "--target", target], cwd=work, env=env
            ).stdout.strip(),
            target,
        )
    verifier = _prepare_identity_verifier(
        work, rustc, env.copy(), target, compiler_verified=bool(modes or target)
    )
    cargo_home = work / "cargo-home"
    cargo_home.mkdir()
    env.update(
        CARGO_HOME=str(cargo_home),
        CARGO_TARGET_DIR=str(work / "target"),
        CARGO_NET_GIT_FETCH_WITH_CLI="true",
    )
    _prepare_git_delivery(delivery, work, env, git_url, revision, tree)
    if dependencies:
        pins = _dependency_pins(dependencies)
        sources = (
            _ci_dependency_bundles(pins, verifier)
            if dependency_sources is None
            else {repository: (path, None) for repository, path in dependency_sources.items()}
        )
        used = [Path(delivery)]
        for index, (repository, pin) in enumerate(sorted(pins.items())):
            source, checksum = sources[repository]
            if any(source.samefile(path) for path in used):
                raise ValueError("Each SDK Git repository requires a distinct delivery")
            used.append(source)
            if checksum is not None:
                snapshot = work / source.name
                shutil.copyfile(source, snapshot)
                with snapshot.open("rb") as stream:
                    if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                        raise ValueError("The additional SDK Git bundle checksum differs")
                source = snapshot
            mirror = _prepare_git_delivery(
                source, work, env, pin["git"], pin["rev"], None, name=f"dependency-{index}.git"
            )
            if (
                dependency_sources is None
                and _git(mirror, "rev-parse", "HEAD^{commit}", env=env) != pin["rev"]
            ):
                raise ValueError(
                    "The CI source bundle HEAD differs from its advertised SDK Git pin"
                )
    fixture = root / "fixtures/rust-consumer"
    client = work / "client"
    client.mkdir()
    shutil.copytree(fixture / "src", client / "src")
    template = (fixture / "Cargo.toml.in").read_text(encoding="utf-8")
    (client / "Cargo.toml").write_text(
        _rust_manifest(
            template,
            git_url,
            packages,
            revision,
            dependencies=dependencies,
            registry_dependencies=registry_dependencies,
            optional={
                name
                for name in packages
                if modes and any(name not in active for _, active in modes.values())
            },
        ),
        encoding="utf-8",
    )
    target_flags = ["--target", target] if target else []
    run([cargo, "generate-lockfile"], cwd=client, env=env)
    run([cargo, "fetch", "--locked", *target_flags], cwd=client, env=env)
    expected = _git_identity(git_url, revision)
    extra_identities = {
        name: _git_identity(pin["git"], pin["rev"]) for name, pin in (dependencies or {}).items()
    }
    lock = (client / "Cargo.lock").read_bytes()
    locked_packages = tomllib.loads(lock.decode())["package"]
    _verify_packages(
        verifier,
        locked_packages,
        packages,
        expected,
        "Cargo.lock",
        dependencies=extra_identities,
        registry=registry_dependencies,
    )
    owned = work / "files"
    owned.mkdir()
    outputs = {}
    platform = target or host_target
    host_evidence = {"windows_host": windows_host} if windows_host else {}
    for mode, (features, active) in (modes or {None: ((), packages)}).items():
        flags = ["--no-default-features"] if mode else []
        if features:
            flags.extend(("--features", ",".join(features)))
        metadata = json.loads(
            run(
                [
                    cargo,
                    "metadata",
                    "--locked",
                    "--offline",
                    "--format-version",
                    "1",
                    *(["--filter-platform", platform] if platform else []),
                    *flags,
                ],
                cwd=client,
                env=env,
            ).stdout
        )
        _check_rust_metadata(
            metadata,
            client,
            cargo_home,
            verifier,
            packages,
            expected,
            dependencies=extra_identities,
            optional=set(packages) - set(active),
            registry_dependencies=registry_dependencies,
        )
        if mode:
            resolved(tree, expected, lock, metadata, mode=mode, **host_evidence)
            files_for_mode = owned / mode
            files_for_mode.mkdir()
        else:
            resolved(tree, expected, lock, metadata, **host_evidence)
            files_for_mode = owned
        locked = ["--locked", "--offline", *target_flags, *flags]
        if windows_architecture:
            output = _run_windows_rust_client(
                run,
                [cargo, "build", *locked],
                cwd=client,
                env=env,
                metadata=metadata,
                architecture=windows_architecture,
                runtime_dir=files_for_mode,
                verifier=verifier,
            )
        else:
            output = run(
                [cargo, "run", *locked, "--", str(files_for_mode)], cwd=client, env=env
            ).stdout
        if mode and mode_completed:
            mode_completed(mode, output)
        outputs[mode] = output
    return outputs if modes else outputs[None]


def _relative(name):
    path = Path(name)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError("Installed C paths must stay inside their declared roots")
    return path


def _c_file(root, name, suffix, *, directory=".", tracked=False):
    relative = _relative(name)
    source = root / relative
    scope = root / directory
    if source.suffix != suffix or not source.is_relative_to(scope):
        raise ValueError("Select a C fixture in the SDK or a JSON receipt under Artifacts")
    resolved = source.resolve(strict=True)
    if not resolved.is_relative_to(scope) or not resolved.is_file():
        raise ValueError("The C fixture or receipt must resolve to a file inside its declared root")
    if tracked:
        for path in {relative, resolved.relative_to(root)}:
            if _git(root, "--literal-pathspecs", "ls-files", "-z", "--", path.as_posix()) != (
                path.as_posix() + "\0"
            ):
                raise ValueError("The C fixture and receipt must be tracked in the SDK")
    return resolved


def _stage_c(root, work, framework, *, c_receipt=_C_RECEIPT):
    path = _c_file(root, c_receipt, ".json", directory="Artifacts")
    receipt = json.loads(path.read_text(encoding="utf-8"))
    for group in ("inputs", "outputs"):
        expected = receipt[group]
        if not expected or hashes([root / _relative(name) for name in expected], root) != expected:
            raise ValueError("The accepted native input/output bytes differ from their receipt")
    install = work / "install"
    install.mkdir()
    shutil.copytree(root / framework, install / framework.name, symlinks=True)
    shutil.copytree(root / "ThirdParty", install / "ThirdParty", symlinks=True)
    if (root / "LICENSE").is_file():
        shutil.copy2(root / "LICENSE", install / "LICENSE", follow_symlinks=False)
    for path in install.rglob("*"):
        if path.is_symlink() and (
            Path(os.readlink(path)).is_absolute()
            or not path.resolve(strict=True).is_relative_to(install)
        ):
            raise ValueError("An installed C payload symlink escapes its copied tree")
    installed = hashes(files(install), install)
    accepted_framework = {
        (Path(framework.name) / path.relative_to(framework)).as_posix(): digest
        for name, digest in receipt["outputs"].items()
        if (path := Path(name)).is_relative_to(framework)
    }
    if (
        not accepted_framework
        or {
            name: digest
            for name, digest in installed.items()
            if Path(name).is_relative_to(framework.name)
        }
        != accepted_framework
    ):
        raise ValueError("The copied framework differs from its accepted output inventory")
    return install, installed


def _run_c(
    root,
    work,
    framework,
    header,
    c_arguments,
    runner=None,
    *,
    c_fixture=_C_FIXTURE,
    c_receipt=_C_RECEIPT,
):
    run = runner or _run
    env = _environment(work)
    install, installed = _stage_c(root, work, framework, c_receipt=c_receipt)
    fixture = _c_file(root, c_fixture, ".c")
    client = work / "client"
    client.mkdir()
    shutil.copy2(fixture, client / "main.c")
    owned = work / "files"
    owned.mkdir()
    binary = client / "consumer"
    dependencies = client / "headers.d"
    command = [
        "/usr/bin/xcrun",
        "clang",
        "-std=c17",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-MD",
        "-MF",
        str(dependencies),
        "-mmacosx-version-min=26.0",
        "main.c",
        "-F",
        str(install),
        "-framework",
        framework.stem,
        "-Wl,-rpath," + str(install),
        "-o",
        str(binary),
    ]
    run(command, cwd=client, env=env)
    dependency_text = dependencies.read_text(encoding="utf-8")
    paths = [
        (client / value).resolve()
        for value in shlex.split(dependency_text.replace("\\\n", ""))
        if not value.endswith(":")
    ]
    resolved = (install / framework.name / "Headers" / header).resolve(strict=True)
    if resolved not in paths or any(path.is_relative_to(root) for path in paths):
        raise ValueError(
            "The C compiler must consume only the installed SDK header, not SDK sources"
        )
    arguments = c_arguments(client, owned) if c_arguments is not None else (owned,)
    runtime = run([str(binary), *map(str, arguments)], cwd=client, env=env)
    if hashes(files(install), install) != installed:
        raise ValueError("The installed C payload changed during compilation or execution")
    return {
        "compileCommand": command,
        "headerDependencies": dependency_text,
        "resolvedFrameworkHeader": str(resolved),
        "installedFiles": installed,
        "runtimeOutput": runtime.stdout,
    }


def check_installed(
    *,
    root,
    git_url,
    rust_packages,
    framework=None,
    header=None,
    c_arguments=None,
    c_fixture=_C_FIXTURE,
    c_receipt=_C_RECEIPT,
    argv=None,
    rust_git_dependencies=None,
    rust_modes=None,
    rust_mode_check=None,
    rust_registry_dependencies=None,
):
    """Run the SDK's own Rust/C API assertions using only independently delivered inputs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Exact tested SDK commit; defaults to clean HEAD")
    parser.add_argument(
        "--git-source",
        type=Path,
        help="Complete local Git repository or self-contained bundle; defaults to this SDK",
    )
    parser.add_argument("--language", choices=("rust", "c"), action="append")
    parser.add_argument(
        "--windows-architecture",
        choices=tuple(windows.MSVC_TARGETS),
        help="Windows Rust target. x64 can run under emulation on ARM64",
    )
    parser.add_argument(
        "--git-dependency-source",
        action="append",
        metavar="[OWNER/REPO=]PATH",
        help="Complete local mirror or bundle for an additional SDK Git repository",
    )
    parser.add_argument(
        "--evidence",
        type=Path,
        help="Retain a JSON report and the client's own Cargo.lock/metadata outside the SDK",
    )
    args = parser.parse_args(argv)
    root = Path(root).resolve(strict=True)
    revision, tree = _source_revision(root, args.revision)
    default_languages = ("rust", "c") if framework and not args.windows_architecture else ("rust",)
    selected = tuple(dict.fromkeys(args.language or default_languages))
    if "c" in selected:
        if framework is None or header is None:
            raise ValueError("This SDK check does not declare an installed C framework and header")
        framework = _relative(framework)
        if framework.parts[0] != "Artifacts" or framework.suffix != ".framework":
            raise ValueError("Select a tracked framework under Artifacts")
        if _relative(header).name != header:
            raise ValueError(
                "Select a public header filename under the framework Headers directory"
            )
    packages = tuple(rust_packages)
    dependencies = _extra_dependencies(rust_git_dependencies, git_url, packages)
    registry_dependencies = _registry_dependencies(
        rust_registry_dependencies, set(packages) | set(dependencies)
    )
    rust_options = {"dependencies": dependencies} if dependencies else {}
    if args.windows_architecture:
        if sys.platform != "win32" or "rust" not in selected:
            raise ValueError("A Windows architecture requires native Windows Rust acceptance")
        rust_options["windows_architecture"] = args.windows_architecture
    if registry_dependencies:
        rust_options["registry_dependencies"] = registry_dependencies
    if rust_modes is not None:
        if (
            not rust_modes
            or not callable(rust_mode_check)
            or any(
                not re.fullmatch(r"[a-z][a-z0-9-]*", label)
                or any(not re.fullmatch(r"[A-Za-z0-9_+.-]+", feature) for feature in features)
                or not active
                or set(active) - set(packages)
                for label, (features, active) in rust_modes.items()
            )
            or set().union(*(set(active) for _, active in rust_modes.values())) != set(packages)
        ):
            raise ValueError(
                "Rust modes must name valid features and cover the public SDK packages"
            )
        rust_options["modes"] = rust_modes
    if args.git_dependency_source:
        if not dependencies or "rust" not in selected:
            raise ValueError("Select the installed Rust consumer and declare its SDK Git sources")
        if os.environ.get("NAVI_CI_SOURCES"):
            raise ValueError("Choose either the CI source manifest or --git-dependency-source")
        rust_options["dependency_sources"] = _local_dependency_sources(
            args.git_dependency_source, _dependency_pins(dependencies)
        )
    if "c" in selected and sys.platform != "darwin":
        raise ValueError("The installed C framework consumer requires owned macOS acceptance")
    destination = args.evidence
    lock_path = None
    metadata_paths = {}
    if destination is not None:
        # Resolve the parent, never the final name of any output file.
        destination = destination.parent.resolve() / destination.name
        if destination.is_relative_to(root):
            raise ValueError("Retained consumer evidence must remain outside the SDK checkout")
        paths = [destination]
        if "rust" in selected:
            lock_path = destination.with_suffix(".Cargo.lock")
            metadata_paths = {
                mode: destination.with_suffix(
                    f".{mode}.cargo-metadata.json" if mode else ".cargo-metadata.json"
                )
                for mode in (rust_modes or (None,))
            }
            paths.extend((lock_path, *metadata_paths.values()))
        for path in paths:
            if os.path.lexists(path):
                raise ValueError(f"Consumer evidence output already exists: {path.name}")
        destination.parent.mkdir(parents=True, exist_ok=True)
    evidence = {
        "sdkRevision": revision,
        "sdkTree": tree,
        "remoteAuthenticationTested": False,
        "nativeRebuilt": False,
        "state": "running",
    }

    def save():
        if report is not None:
            report.seek(0)
            report.write(json.dumps(evidence, indent=2) + "\n")
            report.truncate()
            report.flush()

    def resolved(mirror_tree, git_identity, lock, metadata, *, mode=None, windows_host=None):
        first_resolution = "rust" not in evidence
        rust = evidence.setdefault(
            "rust",
            {
                "delivery": "complete-local-Git-mirror",
                "mirrorTree": mirror_tree,
                "gitIdentity": git_identity,
                "cargoLockSHA256": hashlib.sha256(lock).hexdigest(),
            },
        )
        if mode:
            rust.setdefault("modes", {})[mode] = {
                "state": "resolved",
                "resolvedPackageCount": len(metadata["packages"]),
            }
        else:
            rust["resolvedPackageCount"] = len(metadata["packages"])
        if args.windows_architecture:
            rust["host"] = windows.MSVC_TARGETS[windows_host]
            rust["target"] = windows.MSVC_TARGETS[args.windows_architecture]
        if dependencies:
            rust["gitDependencies"] = {
                name: _git_identity(pin["git"], pin["rev"]) for name, pin in dependencies.items()
            }
        if registry_dependencies:
            rust["registryDependencies"] = {
                name: {
                    "version": pin["version"][1:],
                    "features": pin["features"],
                    "source": _PUBLIC_REGISTRY,
                }
                for name, pin in registry_dependencies.items()
            }
        if lock_path is not None:
            if first_resolution:
                with lock_path.open("xb") as retained_lock:
                    retained_lock.write(lock)
            with metadata_paths[mode].open("x", encoding="utf-8") as retained_metadata:
                retained_metadata.write(json.dumps(metadata, indent=2) + "\n")
        if mode:
            mode_evidence = rust["modes"][mode]
            mode_evidence["checks"] = rust_mode_check(metadata, mode)
            mode_evidence["state"] = "checked"
        save()

    def mode_completed(mode, output):
        evidence["rust"]["modes"][mode].update(state="passed", runtimeOutput=output)
        save()

    if rust_modes:
        rust_options["mode_completed"] = mode_completed

    with destination.open("x", encoding="utf-8") if destination else nullcontext() as report:
        try:
            with tempfile.TemporaryDirectory(prefix="installed-sdk-consumers-") as directory:
                work = Path(directory).resolve()
                if work.is_relative_to(root):
                    raise ValueError("External clients must be outside the SDK workspace")
                for language in selected:
                    task = work / language
                    task.mkdir()
                    if language == "rust":
                        output = _run_rust(
                            root,
                            task,
                            git_url,
                            packages,
                            revision,
                            tree,
                            args.git_source or root,
                            resolved,
                            **rust_options,
                        )
                        if rust_modes:
                            output = "".join(output.values())
                        rust = evidence["rust"]
                        rust["runtimeOutput"] = output
                        if args.windows_architecture:
                            rust["execution"] = (
                                "native" if rust["host"] == rust["target"] else "emulated"
                            )
                    else:
                        _c_file(root, c_receipt, ".json", directory="Artifacts", tracked=True)
                        _c_file(root, c_fixture, ".c", tracked=True)
                        evidence["c"] = _run_c(
                            root,
                            task,
                            framework,
                            header,
                            c_arguments,
                            c_fixture=c_fixture,
                            c_receipt=c_receipt,
                        )
            _source_revision(root, revision)
            evidence["state"] = "passed"
        except Exception as error:
            evidence.update(state="failed", failure=str(error))
            raise
        finally:
            save()
    for language in selected:
        print(evidence[language]["runtimeOutput"], end="")
    print("Exact SDK Git revision/tree: " + revision + " / " + tree)
