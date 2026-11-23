#!/usr/bin/env python3
"""Build and check the Windows x64 SDK and optionally an owned desktop fixture."""

import argparse
import shutil
import sys
from pathlib import Path

from sdk_tooling.adapters import load, support_inputs
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.windows_delivery import X64Acceptance

from distribution.windows_target import RID, TARGET


def main(root=None, argv=None):
    root = Path(root or Path(__file__).resolve().parents[1]).resolve()
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--desktop", action="store_true", help="Run this SDK's separate-process desktop fixture"
    )
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Build and verify native outputs without rerunning tests",
    )
    parser.add_argument(
        "--package-source",
        action="append",
        default=[],
        help="Private/local NuGet source for managed consumers",
    )
    args = parser.parse_args(argv)
    if sys.platform != "win32":
        raise SystemExit("Native Windows is required; cross-compilation is not runtime acceptance.")
    if args.build_only and args.desktop:
        parser.error("--build-only and --desktop select different validation scopes")
    inputs = support_inputs(root)
    native = ffi_product(root)
    windows = load("windows")
    acceptance = X64Acceptance(root)
    env, host, dotnet = acceptance.env, acceptance.host, acceptance.dotnet
    env["DOTNET_BIN"] = dotnet

    def run(command):
        acceptance.run(*command)

    run(["cargo", "fetch", "--locked", "--target", TARGET])
    destination = windows.build_library(native, env, acceptance.tools, "x64", native_host=host)
    if inputs != support_inputs(root):
        raise ValueError("Build support changed during the Windows x64 build")
    if args.build_only:
        print(f"{root.name} Windows x64 artifact built on {host}. Fixtures did not run.")
        return
    run(["cargo", "test", "--workspace", "--locked", "--offline", "--target", TARGET])
    library = destination / (native.library + ".dll")
    with load("artifacts").build_lock(root / ".native-build"):
        windows.verify_artifact(native, architecture="x64", environment=env)
        command = load("binding_checks").command
        run(command("c", "--library", library))
        sources = [
            value for source in args.package_source for value in ("--package-source", source)
        ]
        run(command("dotnet", "--native-root", destination, *sources))
        if args.desktop:
            run_desktop(root, dotnet, env, library, args.package_source, run)
    if inputs != support_inputs(root):
        raise ValueError("Build support changed during Windows x64 fixture checks")
    print(
        root.name
        + " Windows x64 build/C/managed checks"
        + (" and owned desktop fixture" if args.desktop else "")
        + f" passed on {host}."
    )


def require_x64_desktop_target(executable):
    error = "Owned desktop target must be an x64 PE executable"
    with executable.open("rb") as stream:
        dos = stream.read(64)
        if len(dos) != 64 or dos[:2] != b"MZ":
            raise ValueError(error)
        stream.seek(int.from_bytes(dos[60:64], "little"))
        header = stream.read(26)
    executable_image = 0x0002
    dll = 0x2000
    characteristics = int.from_bytes(header[22:24], "little")
    if (
        header[:6] != b"PE\0\0\x64\x86"
        or int.from_bytes(header[20:22], "little") < 2
        or characteristics & (executable_image | dll) != executable_image
        or header[24:26] != b"\x0b\x02"
    ):
        raise ValueError(error)


def run_desktop(root, dotnet, env, library, sources, run):
    project = root / "fixtures/acceptance/windows/host/WindowManagement.WindowsAcceptance.csproj"
    load("dotnet").build_managed(
        dotnet,
        project,
        cwd=root,
        env=env,
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        sources=sources,
        properties={
            "RuntimeIdentifier": RID,
            "UseAppHost": "false",
            "UseSharedCompilation": "false",
        },
        verify_style=True,
    )
    output = project.parent / "bin/Release/net10.0-windows" / RID
    target_directory = root / "target"
    run(
        [
            "cargo",
            "build",
            "-p",
            "window-management-windows",
            "--example",
            "window-acceptance-target",
            "--target",
            TARGET,
            "--target-dir",
            target_directory,
            "--locked",
            "--offline",
        ]
    )
    executable = target_directory / TARGET / "debug/examples/window-acceptance-target.exe"
    require_x64_desktop_target(executable)
    with load("workspaces").temporary_workspace(
        root / ".native-build", prefix="desktop-consumer-"
    ) as workspace:
        app = workspace / "app"
        shutil.copytree(output, app)
        load("artifacts").stage_native(library, app / library.name)
        shutil.copyfile(executable, app / executable.name)
        run(
            [
                dotnet,
                app / (project.stem + ".dll"),
                root / ".native-build/windows/desktop-acceptance",
            ]
        )


if __name__ == "__main__":
    main()
