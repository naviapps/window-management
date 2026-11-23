"""Consumer CLI mechanisms with explicit SDK fixture, library and project paths."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from . import bindings, windows
from .dotnet import subprocess_environment
from .workspaces import temporary_workspace

_SWIFT_DEVELOPER_INPUTS = {
    ".git",
    ".build",
    ".native-build",
    ".swiftpm",
    "__pycache__",
    "target",
    "bin",
    "obj",
    "build",
    "DerivedData",
    "node_modules",
    "tools",
    "crates",
    "sdk_tooling",
}
_SWIFT_CACHE_DIRECTORIES = {".git", ".build", ".native-build", ".swiftpm", "__pycache__"}
_SWIFT_BUILD_SYSTEMS = ("native", "swiftbuild")


def _swift_copy_ignore(directory, names):
    return [
        name
        for name in names
        if name in _SWIFT_CACHE_DIRECTORIES and (Path(directory) / name).is_dir()
    ]


def _copy_swift_inputs(source, destination, inputs):
    for name in inputs:
        relative = Path(name)
        if (
            relative.is_absolute()
            or not relative.parts
            or ".." in relative.parts
            or relative.parts[0] in _SWIFT_DEVELOPER_INPUTS
        ):
            raise ValueError("Swift consumer inputs must exclude developer trees: " + str(name))
        origin = source / relative
        if not origin.resolve(strict=True).is_relative_to(source):
            raise ValueError("Swift consumer input escapes its source: " + str(name))
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_dir() and not origin.is_symlink():
            shutil.copytree(
                origin,
                target,
                symlinks=True,
                ignore=_swift_copy_ignore,
            )
        else:
            shutil.copy2(origin, target, follow_symlinks=False)
    # Keep framework Versions/Current, resources and notices intact, but never
    # allow a link to make the original checkout part of this consumer build.
    for path in destination.rglob("*"):
        if path.is_symlink() and (
            Path(os.readlink(path)).is_absolute()
            or not path.resolve(strict=True).is_relative_to(destination)
        ):
            raise ValueError("Swift consumer link escapes its installed tree: " + str(path))


def _swift_policy_file(sources, destination):
    """Carry root dependency policy without a second copy of SDK pin metadata."""
    found = [path for path in sources if path.exists()]
    if not found:
        return False
    data = found[0].read_bytes()
    if any(path.read_bytes() != data for path in found[1:]):
        raise ValueError("Conflicting Swift consumer dependency policy: " + destination.name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return True


def _check_swift_dependencies(dependency, allowed_roots):
    path = Path(dependency["path"]).resolve(strict=True)
    if not any(path.is_relative_to(root) for root in allowed_roots):
        raise ValueError("Swift consumer dependency escapes its installed tree: " + str(path))
    for child in dependency["dependencies"]:
        _check_swift_dependencies(child, allowed_roots)


def run_swift_consumer(
    *,
    root,
    inputs,
    fixture,
    executables,
    work_parent=None,
    git_config=None,
    mirror_config=None,
    build_system=None,
    warnings_as_errors=True,
    runner=None,
):
    """Build/run an SDK-owned external package against a stripped installable tree.

    The fixture's manifest references ../sdk and owns products/platforms; its
    executables own API/native assertions. This is a fresh source/artifact check,
    not remote publication evidence. No producer tool is invoked.
    """
    root = Path(root).resolve(strict=True)
    fixture = Path(fixture).resolve(strict=True)
    if build_system is not None and build_system not in _SWIFT_BUILD_SYSTEMS:
        raise ValueError("Unsupported SwiftPM build system: " + str(build_system))
    if mirror_config is not None:
        mirror_config = Path(mirror_config).resolve(strict=True)
    executables = tuple(executables)
    if not executables or any(
        not name or Path(name).name != name or name in {".", ".."} for name in executables
    ):
        raise ValueError("Provide consumer executable names without directory components")
    if work_parent is not None:
        work_parent = Path(work_parent).resolve()
        work_parent.mkdir(parents=True, exist_ok=True)
    run = runner or subprocess.run
    with tempfile.TemporaryDirectory(dir=work_parent, prefix="swift-consumer-") as directory:
        work = Path(directory).resolve()
        sdk, consumer = work / "sdk", work / "consumer"
        sdk.mkdir()
        consumer.mkdir()
        _copy_swift_inputs(root, sdk, inputs)
        _copy_swift_inputs(
            fixture,
            consumer,
            [path.name for path in fixture.iterdir() if path.name not in _SWIFT_DEVELOPER_INPUTS],
        )
        if not (sdk / "Package.swift").is_file() or not (consumer / "Package.swift").is_file():
            raise ValueError("Both the installable SDK and consumer need Package.swift")
        # A dependency's Package.resolved does not control a SwiftPM root package.
        pinned = _swift_policy_file(
            [root / "Package.resolved", consumer / "Package.resolved"],
            consumer / "Package.resolved",
        )
        mirrors = Path(".swiftpm/configuration/mirrors.json")
        _swift_policy_file(
            [root / mirrors, fixture / mirrors, *([mirror_config] if mirror_config else [])],
            consumer / mirrors,
        )
        # Only Xcode/system tools are available to manifests and runtime fixtures.
        # Explicit job Git rewrites preserve immutable private dependency mirrors.
        env = {
            key: value
            for key, value in os.environ.items()
            if key
            in {
                "HOME",
                "CFFIXED_USER_HOME",
                "DEVELOPER_DIR",
                "LANG",
                "LC_ALL",
                "LC_CTYPE",
                "TZ",
                "TERM",
                "NO_COLOR",
                "HTTPS_PROXY",
                "HTTP_PROXY",
                "ALL_PROXY",
                "NO_PROXY",
            }
        }
        # Xcode manages mounted developer components below the real user home.
        # Keep that location stable; isolate SwiftPM state with explicit paths.
        for key, relative in {
            "XDG_CACHE_HOME": "cache",
            "XDG_CONFIG_HOME": "config",
            "TMPDIR": "tmp",
            "CLANG_MODULE_CACHE_PATH": "module-cache",
            "SWIFT_MODULECACHE_PATH": "module-cache",
        }.items():
            path = work / relative
            path.mkdir(exist_ok=True)
            env[key] = str(path)
        configuration = work / "gitconfig"
        selected_git = git_config or os.environ.get("GIT_CONFIG_GLOBAL")
        configuration.write_bytes(Path(selected_git).read_bytes() if selected_git else b"")
        env.update(
            PATH="/usr/bin:/bin:/usr/sbin:/sbin",
            GIT_CONFIG_GLOBAL=str(configuration),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
        )
        scratch = work / "scratch"
        command = [
            "/usr/bin/xcrun",
            "swift",
            "build",
            "--scratch-path",
            str(scratch),
            "--cache-path",
            str(work / "swiftpm-cache"),
            "--config-path",
            str(work / "swiftpm-config"),
            "--security-path",
            str(work / "swiftpm-security"),
            "--disable-dependency-cache",
            "--manifest-cache",
            "none",
            *(["--build-system", build_system] if build_system else []),
            "-Xswiftc",
            "-strict-concurrency=complete",
            *(["-Xswiftc", "-warnings-as-errors"] if warnings_as_errors else []),
            *(["--force-resolved-versions"] if pinned else []),
        ]
        graph = run(
            [*command[:2], "package", *command[3:], "show-dependencies", "--format", "json"],
            cwd=consumer,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        # An absolute .package(path:) would otherwise bypass source-tree isolation.
        _check_swift_dependencies(json.loads(graph.stdout), (consumer, sdk, scratch))
        run(command, cwd=consumer, env=env, check=True)
        result = run(
            [*command, "--show-bin-path"],
            cwd=consumer,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        binary = Path(result.stdout.strip()).resolve(strict=True)
        if not binary.is_relative_to(scratch):
            raise ValueError("Swift consumer binary path must remain inside its fresh scratch tree")
        for name in executables:
            run([str(binary / name)], cwd=consumer, env=env, check=True)


def check_swift(*, root, inputs, fixture, executables, work_parent=None, argv=None):
    parser = argparse.ArgumentParser(
        description="Build/run this SDK's external Swift package without its developer tree."
    )
    parser.add_argument(
        "--git-config", type=Path, help="Explicit job-private dependency Git rewrites"
    )
    parser.add_argument("--mirror-config", type=Path, help="Explicit SwiftPM mirrors.json")
    parser.add_argument("--build-system", choices=_SWIFT_BUILD_SYSTEMS, help="SwiftPM build system")
    parser.add_argument(
        "--allow-warnings", action="store_true", help="Do not pass -warnings-as-errors to Swift"
    )
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        raise ValueError("Swift native consumer acceptance requires macOS")
    run_swift_consumer(
        root=root,
        inputs=inputs,
        fixture=fixture,
        executables=executables,
        work_parent=work_parent,
        git_config=args.git_config,
        mirror_config=args.mirror_config,
        build_system=args.build_system,
        warnings_as_errors=not args.allow_warnings,
    )


def _dotnet_host(env, target):
    if sys.platform == "win32":
        host = windows.host_architecture()
        architecture = target or host
        return windows.target_dotnet(host, architecture, env), architecture, host != architecture
    if target is not None:
        raise ValueError("--windows-architecture requires a Windows host")
    executable = env.get("DOTNET_BIN") or shutil.which("dotnet", path=env.get("PATH"))
    if not executable:
        raise ValueError("Install .NET 10 or provide DOTNET_BIN")
    return executable, None, False


def _windows_architecture_option(parser):
    parser.add_argument(
        "--windows-architecture",
        choices=tuple(windows.MSVC_TARGETS),
        help="Windows fixture target. x64 can run under emulation on ARM64",
    )


def check_c(*, source, include_dirs, library, work_parent, argv=None):
    parser = argparse.ArgumentParser(
        description="Compile and execute this SDK's existing C ownership fixture."
    )
    parser.add_argument("--library", type=Path, help="Accepted framework Mach-O or Windows DLL")
    _windows_architecture_option(parser)
    args = parser.parse_args(argv)
    host = windows.host_architecture() if sys.platform == "win32" else None
    if args.windows_architecture and host is None:
        raise ValueError("--windows-architecture requires a Windows host")
    architecture = args.windows_architecture or host
    emulated = (host, architecture) == ("arm64", "x64")
    if host != architecture and not emulated:
        raise ValueError("The C fixture requires a matching native Windows host or x64 emulation")
    library = (args.library or Path(library)).resolve(strict=True)
    work_parent = Path(work_parent).resolve()
    work_parent.mkdir(parents=True, exist_ok=True)
    with temporary_workspace(work_parent, prefix="c-consumer-") as work:
        if architecture:
            import_library = library.with_suffix(".dll.lib")
            if not import_library.is_file():
                raise ValueError("The accepted DLL's MSVC import library is required")
            staged = bindings.stage_native(library, work / library.name)
            windows.require_pe_machine(staged, architecture)
            env, tools = windows.native_msvc_environment(
                host, target_architecture=args.windows_architecture
            )
            executable = work / "abi.exe"
            bindings.compile_c(
                source,
                output=executable,
                compiler=(tools / "cl.exe",),
                style="msvc",
                standard="c11",
                include_dirs=include_dirs,
                libraries=(import_library,),
                env=env,
                cwd=work,
            )
            windows.require_pe_machine(executable, architecture)
            env["PATH"] = str(library.parent) + os.pathsep + env.get("PATH", "")
        elif sys.platform == "darwin":
            env = dict(os.environ)
            framework = next(
                (path for path in library.parents if path.suffix == ".framework"), None
            )
            rpath = framework.parent if framework else library.parent
            executable = work / "abi"
            bindings.compile_c(
                source,
                output=executable,
                compiler=("xcrun", "clang"),
                standard="c11",
                include_dirs=include_dirs,
                libraries=(library,),
                flags=("-Wl,-rpath," + str(rpath),),
                env=env,
                cwd=work,
            )
        else:
            raise ValueError("C acceptance requires native macOS or Windows")
        subprocess.run([str(executable)], cwd=work, env=env, check=True)
    if emulated:
        print("Windows x64 C fixture passed under emulation on ARM64.")


def check_dotnet(
    *, project, nuget_config, framework, library_name, windows_root, work_parent, cwd, argv=None
):
    parser = argparse.ArgumentParser(
        description="Run this SDK's existing managed fixture against accepted native bytes."
    )
    parser.add_argument("--native-root", type=Path)
    parser.add_argument(
        "--package-source", action="append", default=[], help="Private/local NuGet source"
    )
    _windows_architecture_option(parser)
    args = parser.parse_args(argv)
    if sys.platform not in ("darwin", "win32"):
        raise ValueError("Managed native acceptance requires macOS or Windows")
    env = subprocess_environment()
    env["DOTNET_CLI_UI_LANGUAGE"] = "en"
    dotnet, architecture, emulated = _dotnet_host(env, args.windows_architecture)
    project = Path(project).resolve()
    work_parent = Path(work_parent).resolve()
    work_parent.mkdir(parents=True, exist_ok=True)
    with temporary_workspace(work_parent, prefix="managed-consumer-") as work:
        env["NUGET_PACKAGES"] = str(work / "packages")
        output = project.parent / "bin/Release/net10.0"
        properties = {"UseSharedCompilation": "false"}
        if architecture is not None:
            library = (args.native_root or Path(windows_root) / f"win-{architecture}") / (
                library_name + ".dll"
            )
        if args.windows_architecture is not None:
            # Freeze the exact DLL before restoring packages or compiling the fixture.
            library = bindings.stage_native(library, work / "native" / library.name)
            windows.require_pe_machine(library, architecture)
            rid = f"win-{architecture}"
            properties.update(RuntimeIdentifier=rid, UseAppHost="false")
            output /= rid
        bindings.build_managed(
            dotnet,
            project,
            env=env,
            cwd=cwd,
            nuget_config=nuget_config,
            sources=args.package_source,
            properties=properties,
            verify_style=True,
        )
        if architecture is None:
            bindings.stage_native(framework, work / ("lib" + library_name + ".dylib"))
            env["DYLD_LIBRARY_PATH"] = str(work)
        else:
            # Windows resolves the native dependency beside the managed assembly.
            # Stage both in a disposable copy so acceptance cannot alter build outputs.
            runtime = work / "app"
            shutil.copytree(output, runtime)
            bindings.stage_native(library, runtime / library.name)
            output = runtime
        subprocess.run(
            [dotnet, str(output / (project.stem + ".dll"))], cwd=cwd, env=env, check=True
        )
    if emulated:
        print("Windows x64 managed fixture passed under emulation on ARM64.")


def check_nuget(*, package_id, fixture, work_parent, argv=None):
    parser = argparse.ArgumentParser(
        description="Run this SDK's existing fixture using only an isolated local package feed."
    )
    parser.add_argument("package", type=Path)
    parser.add_argument(
        "--dependency", action="append", default=[], type=Path, help="Required local feed package"
    )
    _windows_architecture_option(parser)
    args = parser.parse_args(argv)
    package = args.package.resolve(strict=True)
    with zipfile.ZipFile(package) as archive:
        specifications = [name for name in archive.namelist() if name.endswith(".nuspec")]
        if len(specifications) != 1:
            raise ValueError("A consumer package must contain one nuspec")
        metadata = ET.fromstring(archive.read(specifications[0]))
        metadata = next(
            (element for element in metadata if element.tag.rsplit("}", 1)[-1] == "metadata"), None
        )
        values = (
            {}
            if metadata is None
            else {element.tag.rsplit("}", 1)[-1]: element.text for element in metadata}
        )
    if values.get("id") != package_id or not values.get("version"):
        raise ValueError("Package identity/version does not match this SDK consumer")
    env = subprocess_environment()
    env["DOTNET_CLI_UI_LANGUAGE"] = "en"
    dotnet, architecture, emulated = _dotnet_host(env, args.windows_architecture)
    source = (
        Path(fixture).read_text()
        + '\nConsole.WriteLine("Fresh NuGet consumer loaded the packaged native SDK and dependencies.");\n'
    )
    bindings.run_isolated_consumer(
        dotnet,
        packages=[package, *args.dependency],
        references={package_id: values["version"]},
        source=source,
        work_parent=work_parent,
        env=env,
        runtime=f"win-{architecture}" if args.windows_architecture is not None else None,
        properties={
            "Nullable": "enable",
            "TreatWarningsAsErrors": "true",
            "UseSharedCompilation": "false",
        },
    )
    if emulated:
        print("Windows x64 NuGet fixture passed under emulation on ARM64.")
