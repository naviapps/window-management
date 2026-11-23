"""Native Windows compiler environment and DLL contract verification; no VM effects."""

import ctypes
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from .artifacts import build_lock, files, hashes, publish, write_json
from .dotnet import subprocess_environment

MSVC_TARGETS = {
    "arm64": "aarch64-pc-windows-msvc",
    "x64": "x86_64-pc-windows-msvc",
}
MSVC_MACHINES = {"arm64": 0xAA64, "x64": 0x8664}
MSVC_COMPONENTS = {
    "arm64": "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    "x64": "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
}


def _process_machines():
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    query = getattr(kernel, "IsWow64Process2", None)
    if query is None:
        raise ValueError("Windows native acceptance requires IsWow64Process2")
    kernel.GetCurrentProcess.argtypes = []
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    query.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.USHORT),
        ctypes.POINTER(wintypes.USHORT),
    ]
    query.restype = wintypes.BOOL
    process, native = wintypes.USHORT(), wintypes.USHORT()
    if not query(kernel.GetCurrentProcess(), ctypes.byref(process), ctypes.byref(native)):
        raise ctypes.WinError(ctypes.get_last_error())
    return process.value, native.value


def _executable_machine(path):
    with Path(path).open("rb") as executable:
        dos = executable.read(64)
        if len(dos) != 64 or dos[:2] != b"MZ":
            raise ValueError(f"Invalid Windows DOS header: {path}")
        executable.seek(struct.unpack_from("<I", dos, 0x3C)[0])
        header = executable.read(6)
    if len(header) != 6 or header[:4] != b"PE\0\0":
        raise ValueError(f"Invalid Windows PE header: {path}")
    return struct.unpack("<H", header[4:])[0]


def require_pe_machine(path, architecture):
    """Require the selected Windows machine before loading or executing a PE image."""
    if _executable_machine(path) != MSVC_MACHINES[architecture]:
        raise ValueError(f"Expected target-native {architecture} PE image: {path}")


def require_rust_target_stdlib(path, target):
    libdir = Path(path)
    if not libdir.is_absolute() or not any(
        library.is_file() for library in libdir.glob("libstd-*.rlib")
    ):
        raise ValueError(f"Install the pinned Rust standard library for {target}")


def host_architecture():
    """Require native ARM64 or x64 Windows Python before running SDK fixtures."""
    if sys.platform != "win32":
        raise ValueError("Use an explicitly selected target-native Windows worker")
    process, native = _process_machines()
    architecture = next(
        (name for name, machine in MSVC_MACHINES.items() if machine == native), None
    )
    # x64 emulation on ARM64 may report an unknown WOW64 process machine.
    if process or architecture is None or _executable_machine(sys.executable) != native:
        raise ValueError(
            "Use an explicitly selected target-native Windows worker with native Python"
        )
    return architecture


def _verify_msvc_libraries(env, vc, target):
    sdk = Path(env.get("WINDOWSSDKDIR", ""))
    version = env.get("WINDOWSSDKVERSION", "").rstrip("\\/")
    if not sdk.is_absolute() or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
        raise ValueError("MSVC developer shell did not select a Windows SDK version")
    directories = [
        Path(value)
        for entry in env.get("LIB", "").split(";")
        if (value := entry.strip().strip('"'))
    ]
    if any(not directory.is_absolute() for directory in directories):
        raise ValueError("Cross-target MSVC requires absolute LIB directories")
    sdk_lib = sdk / "Lib" / version
    for name, expected_directory in (
        ("libcmt.lib", vc / "lib" / target),
        ("libvcruntime.lib", vc / "lib" / target),
        ("libucrt.lib", sdk_lib / "ucrt" / target),
        ("kernel32.lib", sdk_lib / "um" / target),
    ):
        first = next(
            (
                candidate.resolve()
                for directory in directories
                if (candidate := directory / name).is_file()
            ),
            None,
        )
        expected = (expected_directory / name).resolve()
        if first != expected:
            raise ValueError(f"The {target} developer shell must find {name} first at {expected}")


def native_msvc_environment(architecture, environment=None, *, target_architecture=None):
    """Select native MSVC host tools for a Windows target without a managed SDK."""
    target_architecture = architecture if target_architecture is None else target_architecture
    if not isinstance(target_architecture, str) or target_architecture not in MSVC_TARGETS:
        raise ValueError("Select MSVC target arm64 or x64")
    if architecture != host_architecture():
        raise ValueError("Use an explicitly selected target-native Windows worker")
    env = {key.upper(): value for key, value in (environment or os.environ).items()}
    env["VSLANG"] = "1033"
    vswhere = Path(env["PROGRAMFILES(X86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
    components = dict.fromkeys(
        MSVC_COMPONENTS[item] for item in (architecture, target_architecture)
    )
    installation = subprocess.check_output(
        [
            str(vswhere),
            "-latest",
            "-products",
            "*",
            "-requires",
            *components,
            "-property",
            "installationPath",
        ],
        env=env,
        text=True,
    ).strip()
    if not installation or any(char in installation for char in '"\r\n\0'):
        raise ValueError("Install the target-native Visual Studio C++ tools")
    command = (
        'call "'
        + installation
        + '\\Common7\\Tools\\VsDevCmd.bat" -no_logo -arch='
        + target_architecture
        + " -host_arch="
        + architecture
        + " && set"
    )
    for line in subprocess.check_output(command, shell=True, text=True, env=env).splitlines():
        key, separator, value = line.partition("=")
        if separator and key:
            env[key.upper()] = value
    return env, _selected_msvc_tools(env, architecture, target_architecture)


def _selected_msvc_tools(env, architecture, target_architecture):
    if (
        env.get("VSCMD_ARG_TGT_ARCH", "").lower() != target_architecture
        or env.get("VSCMD_ARG_HOST_ARCH", "").lower() != architecture
    ):
        raise ValueError("MSVC host/target architecture differs from the selected worker")
    vc = Path(env.get("VCTOOLSINSTALLDIR", ""))
    tools = vc / ("bin/Host" + architecture) / target_architecture
    if not tools.is_absolute():
        raise ValueError("MSVC developer shell did not supply an absolute tools directory")
    for name in ("cl.exe", "link.exe"):
        expected = tools / name
        selected = shutil.which(name, path=env.get("PATH", ""))
        if not selected or Path(selected).resolve() != expected.resolve():
            raise ValueError(
                f"MSVC developer shell did not select {architecture}-hosted {target_architecture} {name}"
            )
        try:
            actual = _executable_machine(expected)
        except OSError as error:
            raise ValueError(f"Cannot read the selected MSVC {name}") from error
        if actual != MSVC_MACHINES[architecture]:
            raise ValueError(f"Expected {architecture}-hosted MSVC {name}")
    triple = MSVC_TARGETS[target_architecture]
    target = triple.replace("-", "_")
    if target_architecture != architecture:
        _verify_msvc_libraries(env, vc, target_architecture)
        # cc-rs checks the literal target triple before the underscore alias.
        aliases = {"cc_" + triple, "cc_" + target}
        for key in tuple(env):
            if key.lower() in aliases:
                del env[key]
        env["CC_" + target] = str(tools / "cl.exe")
    env["CARGO_TARGET_" + target.upper() + "_LINKER"] = str(tools / "link.exe")
    return tools


def native_environment(architecture="arm64", environment=None, *, target_architecture=None):
    """Prepare native MSVC and target .NET for Windows SDK build and acceptance."""
    target = architecture if target_architecture is None else target_architecture
    emulated = (architecture, target) == ("arm64", "x64")
    if target != architecture and not emulated:
        raise ValueError("Select the native Windows target or x64 on ARM64")
    env, tools = native_msvc_environment(
        architecture, environment, target_architecture=target_architecture
    )
    env = subprocess_environment(env)
    env["DOTNET_CLI_UI_LANGUAGE"] = "en"
    encoded = env.get("CARGO_ENCODED_RUSTFLAGS")
    flags = encoded.split("\x1f") if encoded else shlex.split(env.get("RUSTFLAGS", ""))
    flags.append("-Ctarget-feature=+crt-static")
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(flags)
    return env, tools, target_dotnet(architecture, target, env)


def target_dotnet(host, target, env):
    """Resolve .NET for the selected Windows target and its child processes."""
    if host == target:
        return native_dotnet(target, env)
    if (host, target) != ("arm64", "x64"):
        raise ValueError("Select the native Windows target or x64 on ARM64")
    dotnet = native_dotnet(target, env, require_absolute=True)
    dotnet_root = str(Path(dotnet).parent)
    overrides = {"DOTNET_BIN", "DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_HOST_PATH"}
    for key in tuple(env):
        if key.upper() in overrides:
            del env[key]
    env.update(DOTNET_BIN=dotnet, DOTNET_ROOT=dotnet_root, DOTNET_ROOT_X64=dotnet_root)
    return dotnet


def native_dotnet(architecture, env, *, require_absolute=False):
    """Resolve the .NET 10 SDK and check its process architecture without MSVC."""
    dotnet = env.get("DOTNET_BIN")
    if require_absolute:
        executable = Path(dotnet or "")
        if not executable.is_absolute() or not executable.is_file():
            raise ValueError(
                f"Set DOTNET_BIN to the absolute path of the {architecture} .NET 10 executable"
            )
        executable = executable.resolve(strict=True)
        require_pe_machine(executable, architecture)
        dotnet = str(executable)
    else:
        dotnet = dotnet or shutil.which("dotnet", path=env.get("PATH"))
    if not dotnet:
        raise ValueError("Install target-native .NET 10 or set DOTNET_BIN")
    info = subprocess.check_output([dotnet, "--info"], env=env, text=True)
    version = subprocess.check_output([dotnet, "--version"], env=env, text=True).strip()
    if not re.search(r"Architecture:\s+" + architecture + r"\b", info) or not version.startswith(
        "10."
    ):
        raise ValueError("Use the target-native .NET 10 SDK")
    return dotnet


def verify_library(library, headers, symbol_prefix, tools, env, architecture="arm64"):
    """Verify the native SDK's public ABI and static CRT from the DLL bytes."""
    machine = MSVC_MACHINES[architecture]
    text = "\n".join(Path(header).read_text() for header in headers)
    if not re.fullmatch(r"[A-Za-z_]\w*", symbol_prefix):
        raise ValueError("A C identifier prefix is required")
    expected = set(re.findall(r"\b(" + re.escape(symbol_prefix) + r"\w*)\s*\(", text))
    if not expected:
        raise ValueError("The SDK's C header must declare public exports")
    imports = inspect_pe(Path(library), machine, expected)["imports"]
    if any(re.search(r"vcruntime|msvcp\d|ucrtbase|api-ms-win-crt", name) for name in imports):
        raise ValueError("Native DLL requires a separately installed VC/UCRT runtime")
    return expected


def inspect_pe(path, machine, symbols, *, allow_import=None):
    """Read PE32+ metadata without executing foreign code or depending on dumpbin."""
    data = path.read_bytes()

    def unpack(fmt, offset):
        try:
            return struct.unpack_from(fmt, data, offset)
        except struct.error as error:
            raise ValueError("Truncated PE metadata") from error

    if data[:2] != b"MZ":
        raise ValueError("Missing DOS signature")
    (pe,) = unpack("<I", 0x3C)
    if data[pe : pe + 4] != b"PE\0\0":
        raise ValueError("Missing PE signature")
    actual, sections, _, _, _, opt_size, flags = unpack("<HHIIIHH", pe + 4)
    opt = pe + 24
    table = opt + opt_size
    if opt_size < 128 or table + sections * 40 > len(data):
        raise ValueError("Truncated PE headers")
    if actual != machine or not flags & 0x2000 or unpack("<H", opt)[0] != 0x20B:
        raise ValueError("Expected a target-native 64-bit DLL")
    directory_count = unpack("<I", opt + 108)[0]
    if not 2 <= directory_count <= (opt_size - 112) // 8:
        raise ValueError("Invalid PE directory count")
    if directory_count > 13 and any(unpack("<II", opt + 112 + 13 * 8)):
        raise ValueError("Delay-loaded dependencies are not allowed")
    ranges = []
    for i in range(sections):
        _, virtual_size, virtual, size, raw = unpack("<8sIIII", table + i * 40)
        ranges.append((virtual, size, raw, virtual_size))

    def offset(rva, count=1):
        for virtual, size, raw, _ in ranges:
            delta = rva - virtual
            if 0 <= delta and delta + count <= size and raw + delta + count <= len(data):
                return raw + delta
        raise ValueError("PE RVA is outside initialized section data")

    def name(rva):
        at = offset(rva)
        end = data.find(b"\0", at, min(len(data), at + 4096))
        if end < 0:
            raise ValueError("Unterminated PE name")
        offset(rva, end - at + 1)
        return data[at:end].decode("ascii")

    export_rva, export_size, import_rva, import_size = unpack("<IIII", opt + 112)
    if not export_rva or export_size < 40:
        raise ValueError("Missing export directory")
    export = offset(export_rva, 40)
    function_count, count, functions, names, ordinals = unpack("<IIIII", export + 20)
    if count > len(data) // 4 or function_count > len(data) // 4:
        raise ValueError("Invalid export count")
    named = [name(unpack("<I", offset(names + i * 4, 4))[0]) for i in range(count)]
    if named != sorted(symbols):
        raise ValueError("DLL exports differ from the public C header")
    named_ordinals = set()
    for i in range(count):
        (ordinal,) = unpack("<H", offset(ordinals + i * 2, 2))
        if ordinal >= function_count:
            raise ValueError("Invalid export ordinal")
        named_ordinals.add(ordinal)
    for ordinal in range(function_count):
        (address,) = unpack("<I", offset(functions + ordinal * 4, 4))
        if not address:
            if ordinal in named_ordinals:
                raise ValueError("Named C export has no address")
            continue
        if ordinal not in named_ordinals:
            raise ValueError("Ordinal-only C exports are not allowed")
        if export_rva <= address < export_rva + export_size:
            raise ValueError("Forwarded C exports are not allowed")
        offset(address)
    if bool(import_rva) != bool(import_size):
        raise ValueError("Invalid import directory coverage")
    imports = []
    if import_rva:
        for i in range(import_size // 20):
            descriptor = unpack("<IIIII", offset(import_rva + i * 20, 20))
            if not any(descriptor):
                break
            imports.append(name(descriptor[3]).lower())
        else:
            raise ValueError("Unterminated import directory")
    for library in imports:
        if allow_import is not None and not allow_import(library):
            raise ValueError("Unexpected runtime dependency: " + library)
    return {"machine": hex(actual), "exports": named, "imports": sorted(set(imports))}


def tool_inputs(builder):
    return dict(builder.tool_inputs(), **hashes([Path(__file__)], Path(__file__).parent))


def _output(builder, architecture, output_root):
    if architecture not in ("arm64", "x64"):
        raise ValueError("Select arm64 or x64 explicitly")
    parent = (
        Path(output_root) if output_root is not None else builder.root / ".native-build/windows"
    )
    boundary = (builder.root / ".native-build").resolve()
    if not parent.resolve().is_relative_to(boundary) or parent.is_symlink():
        raise ValueError("Windows output must stay in the SDK native build directory")
    target = MSVC_TARGETS[architecture]
    return parent / ("win-" + architecture), target


def verify_artifact(
    builder,
    architecture="arm64",
    *,
    output_root=None,
    source_inputs=None,
    inspect=None,
    environment=None,
):
    """Verify retained bytes, source/tool policy and optional PE/dependency contracts.

    SDKs may select one output root per library and provide stricter inspection.
    This never executes a DLL or claims runtime acceptance.
    """
    destination, target = _output(builder, architecture, output_root)
    receipt_path = destination / "native-build.json"
    receipt = json.loads(receipt_path.read_text())
    if (
        receipt.get("schema") != 2
        or receipt.get("target") != target
        or receipt.get("inputs") != (source_inputs or builder.build_sources)()
        or receipt.get("toolInputs") != tool_inputs(builder)
    ):
        raise ValueError("Windows native sources or build contract changed")
    if not receipt.get("compiler", "").startswith("rustc " + builder.compiler + " "):
        raise ValueError("Windows native compiler differs from its pin")
    outputs = hashes([p for p in files(destination) if p != receipt_path], destination)
    if receipt.get("outputs") != outputs:
        raise ValueError("Windows native artifact differs from its receipt")
    if inspect and receipt.get("inspection") != inspect(destination / (builder.library + ".dll")):
        raise ValueError("Windows native inspection differs from its receipt")
    if environment is not None and receipt.get("dependencies") != builder.dependencies(
        environment, targets=[target]
    ):
        raise ValueError("Windows native dependency source differs from its receipt")
    return destination, receipt


def _build_driver(env, cross, parent):
    if not cross:
        if sys.platform != "win32":
            raise ValueError(
                "A selected native Windows worker is required; cross builds require explicit opt-in"
            )
        return ["cargo", "build"], {"backend": "msvc"}
    driver = shutil.which("cargo-xwin", path=env.get("PATH"))
    clang = shutil.which("clang-cl", path=env.get("PATH"))
    if not driver or not clang:
        raise ValueError("Cross builds require preinstalled cargo-xwin and LLVM clang-cl")
    env.setdefault("XWIN_CACHE_DIR", str(parent / "xwin"))
    return ["cargo", "xwin", "build"], {
        "backend": "cargo-xwin",
        "version": subprocess.check_output([driver, "--version"], env=env, text=True).strip(),
        "clang-cl": subprocess.check_output([clang, "--version"], env=env, text=True).strip(),
        "requestedMicrosoftVersions": {
            key: env[key]
            for key in ("XWIN_VERSION", "XWIN_SDK_VERSION", "XWIN_CRT_VERSION")
            if key in env
        },
    }


def build_library(
    builder,
    env,
    tools=None,
    architecture="arm64",
    *,
    output_root=None,
    cross=False,
    native_host=None,
    source_inputs=None,
    inspect=None,
    stage_extra=None,
):
    """Build/stage/publish one library under a checkout-wide lock.

    SDK callbacks own extra layout and PE/import policy. The common mechanism owns
    pinned compilation, source/dependency drift checks, receipts and rollback.
    Native and cross compilation produce candidates, never runtime test results.
    """
    destination, target = _output(builder, architecture, output_root)
    parent = destination.parent
    env = dict(env, CARGO_TARGET_DIR=str(parent / "target"), CARGO_PROFILE_RELEASE_STRIP="none")
    compiler_host = target
    rustc = "rustc"
    if native_host is not None:
        if cross or (
            native_host != architecture and (native_host, architecture) != ("arm64", "x64")
        ):
            raise ValueError("Select native MSVC for the native Windows target or x64 on ARM64")
        if host_architecture() != native_host:
            raise ValueError(f"Use native {native_host.upper()} Windows to build {architecture}")
        selected = _selected_msvc_tools(env, native_host, architecture)
        if tools is not None and Path(tools).resolve() != selected.resolve():
            raise ValueError("MSVC tools differ from the selected Windows host and target")
        tools = selected
        compiler_host = MSVC_TARGETS[native_host]
        env["RUSTUP_AUTO_INSTALL"] = "0"
        selected_rustc = shutil.which(rustc, path=env.get("PATH", ""))
        if not selected_rustc:
            raise ValueError("Select the pinned native Rust compiler before building")
        rustc = str(Path(selected_rustc).absolute())
        env["RUSTC"] = rustc
    encoded = env.get("CARGO_ENCODED_RUSTFLAGS")
    flags = encoded.split("\x1f") if encoded else shlex.split(env.get("RUSTFLAGS", ""))
    flags.append("-Ctarget-feature=+crt-static")
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(flags)
    inputs_for = source_inputs or (lambda: builder.build_sources())
    if cross and inspect is None:
        raise ValueError("Cross builds require a portable SDK DLL inspection policy")
    with build_lock(builder.root / ".native-build"):
        command, toolchain = _build_driver(env, cross, parent)
        compiler = subprocess.check_output(
            [rustc, "--version", "--verbose"], cwd=builder.root, env=env, text=True
        )
        if not compiler.startswith("rustc " + builder.compiler + " ") or (
            not cross and f"host: {compiler_host}" not in compiler.splitlines()
        ):
            raise ValueError(
                "Use the pinned native Rust compiler, or explicitly select a cross build"
            )
        if compiler_host != target:
            require_rust_target_stdlib(
                subprocess.check_output(
                    [rustc, "--print", "target-libdir", "--target", target],
                    cwd=builder.root,
                    env=env,
                    text=True,
                ).strip(),
                target,
            )
        if native_host is not None:
            toolchain.update(host=compiler_host, target=target)
        builder.retain_notices(env)
        dependencies = builder.dependencies(env, targets=[target])
        inputs = inputs_for()
        subprocess.run(
            command
            + ["-p", builder.package, "--release", "--target", target, "--locked", "--offline"],
            cwd=builder.root,
            env=env,
            check=True,
        )
        library = Path(env["CARGO_TARGET_DIR"]) / target / "release" / (builder.library + ".dll")
        inspection = (
            inspect(library)
            if inspect
            else {
                "exports": sorted(
                    verify_library(
                        library,
                        (builder.ffi / "include").rglob("*.h"),
                        builder.symbol_prefix,
                        tools,
                        env,
                        architecture,
                    )
                )
            }
        )
        if (
            inputs_for() != inputs
            or builder.dependencies(dict(env), targets=[target]) != dependencies
        ):
            raise ValueError("Native sources or dependencies changed during the Windows build")
        parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            previous = json.loads((destination / "native-build.json").read_text())
            expected = set(previous["outputs"]) | {"native-build.json"}
            if (
                previous.get("target") != target
                or set(hashes(files(destination), destination)) != expected
            ):
                raise ValueError("Windows output contains files outside its previous receipt")
        with tempfile.TemporaryDirectory(prefix="stage-", dir=parent) as temporary:
            stage = Path(temporary) / destination.name
            stage.mkdir()
            shutil.copyfile(library, stage / library.name)
            shutil.copyfile(library.with_suffix(".dll.lib"), stage / (library.name + ".lib"))
            pdb = library.with_suffix(".pdb")
            if pdb.exists():
                shutil.copyfile(pdb, stage / pdb.name)
            if stage_extra:
                stage_extra(stage)
            else:
                shutil.copytree(builder.root / "ThirdParty", stage / "ThirdParty")
                if (builder.root / "LICENSE").is_file():
                    shutil.copyfile(builder.root / "LICENSE", stage / "LICENSE")
            if (
                inputs_for() != inputs
                or builder.dependencies(dict(env), targets=[target]) != dependencies
            ):
                raise ValueError("Native sources or dependencies changed during Windows staging")
            write_json(
                stage / "native-build.json",
                dict(
                    schema=2,
                    target=target,
                    architecture=architecture,
                    compiler=compiler,
                    inputs=inputs,
                    dependencies=dependencies,
                    toolInputs=tool_inputs(builder),
                    outputs=hashes(files(stage), stage),
                    inspection=inspection,
                    exports=inspection["exports"],
                    toolchain=toolchain,
                    crt="static",
                    windowsRuntimeTested=False,
                ),
            )
            publish(
                stage,
                destination,
                lambda: verify_artifact(
                    builder,
                    architecture,
                    output_root=output_root,
                    source_inputs=inputs_for,
                    inspect=inspect,
                    environment=env,
                ),
            )
        return destination
