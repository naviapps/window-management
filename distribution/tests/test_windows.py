"""Check Python Windows x64 producer and consumer routing without a Windows worker."""

import hashlib
import importlib
import json
import os
import struct
import sys
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import Mock, call, patch

from sdk_tooling import windows_delivery

windows = importlib.import_module("distribution.windows_target")
build = importlib.import_module("distribution.verify_windows_native")
pack = importlib.import_module("distribution.pack_nuget")
ci = importlib.import_module("distribution.verify_windows")


class WindowsToolsTests(unittest.TestCase):
    def test_pack_rejects_arm64_before_loading_native_artifacts(self):
        with (
            patch.object(pack, "ffi_product") as product,
            patch.object(pack, "xcframework") as framework,
            patch.object(sys, "stderr"),
            self.assertRaises(SystemExit) as rejected,
        ):
            pack.main(["--runtime", "win-arm64"])
        self.assertEqual(rejected.exception.code, 2)
        product.assert_not_called()
        framework.assert_not_called()

    def test_pack_uses_the_framework_only_when_a_mac_runtime_is_selected(self):
        for runtimes, requires_framework in (
            (("win-x64",), False),
            (("osx-arm64", "osx-x64"), True),
            (("win-x64", "osx-arm64", "osx-x64"), True),
        ):
            nuget = Mock()
            modules = {"artifacts": Mock(files=Mock(return_value=())), "nuget": nuget}
            with (
                self.subTest(runtimes=runtimes),
                patch.object(pack, "ffi_product") as product,
                patch.object(pack, "xcframework") as framework,
                patch.object(pack, "load", side_effect=modules.__getitem__),
            ):
                command = [argument for rid in runtimes for argument in ("--runtime", rid)]
                pack.main(command)
                selected, unused = (
                    (framework, product) if requires_framework else (product, framework)
                )
                selected.assert_called_once_with(Path(pack.__file__).resolve().parents[1])
                unused.assert_not_called()
                nuget.pack_native.assert_called_once()
                call_ = nuget.pack_native.call_args
                self.assertEqual(call_.args, (selected.return_value,))
                self.assertEqual(call_.kwargs["runtimes"], list(runtimes))

    def test_windows_build_selects_native_tools_for_the_x64_target(self):
        for host in ("x64", "arm64"):
            with (
                self.subTest(host=host),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory).resolve()
                (root / "global.json").write_text(
                    '{"sdk":{"version":"10.0.403","rollForward":"disable"}}'
                )
                backend = Mock(MSVC_TARGETS=windows_delivery.windows.MSVC_TARGETS)
                backend.host_architecture.return_value = host
                compiler, dotnet = root / "msvc", str(root / "dotnet.exe")
                environment = {}
                backend.native_environment.return_value = environment, compiler, dotnet
                native = Mock()
                with (
                    patch.object(sys, "platform", "win32"),
                    patch.dict(os.environ, {"DOTNET_HOST_PATH": "host default"}, clear=True),
                    patch.object(build, "load", return_value=backend),
                    patch.object(build, "support_inputs", return_value={}),
                    patch.object(build, "ffi_product", return_value=native),
                    patch.object(windows_delivery, "windows", backend),
                    patch.object(
                        windows_delivery.subprocess, "check_output", return_value="10.0.403\n"
                    ),
                    patch.object(windows_delivery.subprocess, "run") as run,
                    patch("builtins.print"),
                ):
                    build.main(root=root, argv=["--build-only"])
                backend.native_environment.assert_called_once_with(
                    host, {}, target_architecture="x64"
                )
                backend.build_library.assert_called_once_with(
                    native, environment, compiler, "x64", native_host=host
                )
                self.assertEqual(environment["DOTNET_BIN"], dotnet)
                self.assertEqual(
                    run.call_args.args[0],
                    ["cargo", "fetch", "--locked", "--target", windows.TARGET],
                )

    def test_hosted_evidence_contains_only_the_installed_x64_package(self):
        for changed, desktop in (
            (None, True),
            (None, False),
            ("package", False),
            ("support", False),
        ):
            with (
                self.subTest(package_changed=changed, desktop=desktop),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory).resolve()
                output = root / "evidence"
                (root / "Cargo.toml").write_text('[workspace.package]\nversion = "0.1.0"\n')
                native = root / ".native-build/windows/win-x64/native-build.json"
                package = root / ".native-build/packages/NaviApps.WindowManagement.0.1.0.nupkg"
                seen = []
                sdk = str(root / "tooling/ci/run_sdk_tooling.py")

                checker = "distribution/verify_windows_native.py"
                packer = "distribution/pack_nuget.py"

                def run(command, **_options):
                    if command[1] == "run-sdk-fixture":
                        script, *arguments = command[2:]
                        seen.append(script)
                    else:
                        script, arguments = "nuget-consumer", command[1:]
                        seen.append(script)
                    if script == checker:
                        self.assertEqual(arguments, ["--desktop"] if desktop else [])
                        native.parent.mkdir(parents=True)
                        native.write_text("{}")
                    elif script == packer:
                        self.assertEqual(arguments, ["--runtime", "win-x64"])
                        package.parent.mkdir(parents=True)
                        package.write_bytes(b"accepted")
                        package.with_suffix(".nupkg.json").write_text(
                            json.dumps(
                                {
                                    "runtimes": ["win-x64"],
                                    "nativeReceipts": {
                                        "win-x64": hashlib.sha256(native.read_bytes()).hexdigest()
                                    },
                                    "sha256": hashlib.sha256(b"accepted").hexdigest(),
                                }
                            )
                        )
                    else:
                        self.assertEqual(
                            arguments,
                            ["-I", "-B", sdk, "nuget-consumer", str(package)],
                        )
                        if changed == "package":
                            package.write_bytes(b"changed after acceptance")

                options = [] if desktop else ["--skip-desktop"]
                (native.parent.parent / "desktop-acceptance").mkdir(parents=True)
                env = {
                    "VM_RUNNER_ARTIFACTS_DIR": str(output),
                    "DOTNET_BIN": str(root / "dotnet.exe"),
                }
                backend = Mock()
                backend.host_architecture.return_value = "arm64"
                tooling = Mock()
                tooling.command.return_value = [
                    sys.executable,
                    "-I",
                    "-B",
                    sdk,
                    "nuget-consumer",
                    package,
                ]
                with (
                    patch.object(sys, "platform", "win32"),
                    patch.dict(os.environ, env, clear=True),
                    patch.object(
                        ci,
                        "load",
                        side_effect={"windows": backend, "consumers.nuget": tooling}.__getitem__,
                    ),
                    patch.object(
                        ci,
                        "support_inputs",
                        side_effect=[{}, {"build.py": "updated"} if changed == "support" else {}],
                    ),
                    patch.object(
                        ci,
                        "python_command",
                        side_effect=lambda selected_root, *arguments: [
                            sys.executable,
                            "run-sdk-fixture",
                            *arguments,
                        ],
                    ) as python_command,
                    patch.object(ci.subprocess, "run", side_effect=run),
                ):
                    if changed:
                        with self.assertRaisesRegex(ValueError, f"{changed} changed"):
                            ci.main(root=root, argv=options)
                    else:
                        ci.main(root=root, argv=options)
                tooling.command.assert_called_once_with(package)
                self.assertEqual(
                    python_command.call_args_list,
                    [
                        call(root, checker, *([] if not desktop else ["--desktop"])),
                        call(root, packer, "--runtime", "win-x64"),
                    ],
                )
                self.assertEqual(seen, [checker, packer, "nuget-consumer"])
                backend.target_dotnet.assert_called_once_with("arm64", "x64", env)
                expected = {"win-x64", "desktop-acceptance"} if desktop else {"win-x64"}
                self.assertEqual({p.name for p in (output / "sdk-windows").iterdir()}, expected)
                published = output / "sdk-packages" / package.name
                if changed:
                    self.assertFalse(published.exists())
                else:
                    self.assertEqual(published.read_bytes(), b"accepted")

    def test_desktop_stages_only_the_verified_x64_target_before_running_managed_tests(self):
        dos_header = bytearray(64)
        dos_header[:2] = b"MZ"
        struct.pack_into("<I", dos_header, 60, len(dos_header))
        x64 = struct.pack("<4sH14xHHH", b"PE\0\0", 0x8664, 240, 0x0002, 0x020B)
        arm64 = struct.pack("<4sH14xHHH", b"PE\0\0", 0xAA64, 240, 0x0002, 0x020B)
        x64_dll = struct.pack("<4sH14xHHH", b"PE\0\0", 0x8664, 240, 0x2002, 0x020B)
        for name, binary in (
            ("x64", dos_header + x64),
            ("arm64", dos_header + arm64),
            ("dll", dos_header + x64_dll),
            ("truncated", dos_header + x64[:20]),
            ("bad DOS header", b"\0" * 64 + x64),
        ):
            with self.subTest(binary=name):
                self.check_desktop_target(binary, accepted=name == "x64")

    def check_desktop_target(self, binary, *, accepted):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            parent = root / ".native-build"
            workspace = parent / "desktop-consumer-test"
            workspace.mkdir(parents=True)
            project = root / "fixtures/acceptance/windows/host"
            output = project / "bin/Release/net10.0-windows/win-x64"
            output.mkdir(parents=True)
            (output / "WindowManagement.WindowsAcceptance.dll").write_bytes(b"managed fixture")
            library = parent / "window_management_ffi.dll"
            artifacts, dotnet, workspaces = Mock(), Mock(), Mock()
            workspaces.temporary_workspace.return_value = nullcontext(workspace)
            run = Mock()
            executable = (
                root / "target" / windows.TARGET / "debug/examples/window-acceptance-target.exe"
            )
            executable.parent.mkdir(parents=True)
            executable.write_bytes(binary)
            build_target = call(
                [
                    "cargo",
                    "build",
                    "-p",
                    "window-management-windows",
                    "--example",
                    "window-acceptance-target",
                    "--target",
                    windows.TARGET,
                    "--target-dir",
                    root / "target",
                    "--locked",
                    "--offline",
                ]
            )
            tooling = {"artifacts": artifacts, "dotnet": dotnet, "workspaces": workspaces}
            with patch.object(build, "load", side_effect=tooling.get):
                if not accepted:
                    with self.assertRaisesRegex(ValueError, "x64 PE executable"):
                        build.run_desktop(root, "dotnet", {}, library, (), run)
                    self.assertEqual(run.call_args_list, [build_target])
                    artifacts.stage_native.assert_not_called()
                    workspaces.temporary_workspace.assert_not_called()
                    return
                build.run_desktop(root, "dotnet", {}, library, (), run)
            workspaces.temporary_workspace.assert_called_once_with(
                parent, prefix="desktop-consumer-"
            )
            app = workspace / "app"
            artifacts.stage_native.assert_called_once_with(library, app / library.name)
            self.assertEqual((app / executable.name).read_bytes(), executable.read_bytes())
            self.assertEqual(
                run.call_args_list,
                [
                    build_target,
                    call(
                        [
                            "dotnet",
                            app / "WindowManagement.WindowsAcceptance.dll",
                            parent / "windows/desktop-acceptance",
                        ]
                    ),
                ],
            )


if __name__ == "__main__":
    unittest.main()
