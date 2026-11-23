"""Check Python Windows x64 producer and consumer routing without a Windows worker."""

import hashlib
import importlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
windows = importlib.import_module("_windows")
build = importlib.import_module("check-windows")
pack = importlib.import_module("pack-dotnet")
ci = importlib.import_module("check-ci")


class WindowsToolsTests(unittest.TestCase):
    def test_pack_rejects_arm64_before_loading_native_artifacts(self):
        with (
            patch.object(pack, "builder") as builder,
            patch.object(sys, "stderr"),
            self.assertRaises(SystemExit) as rejected,
        ):
            pack.main(["--runtime", "win-arm64"])
        self.assertEqual(rejected.exception.code, 2)
        builder.assert_not_called()

    def test_candidate_windows_consumer_passes_x64_to_the_shared_driver(self):
        with (
            patch.object(sys, "platform", "win32"),
            patch.object(windows, "select_candidate") as select,
        ):
            result = windows.consumer_options(
                ["package.nupkg", "--tooling-source", "candidate", "--tooling-revision", "a" * 40]
            )
        self.assertEqual(result, ["package.nupkg", "--windows-architecture", "x64"])
        self.assertEqual(select.call_args.args[1].tooling_source, Path("candidate"))

    def test_windows_arm64_without_candidate_stops_before_a_native_build(self):
        with (
            patch.object(sys, "platform", "win32"),
            patch.object(windows.platform, "machine", return_value="ARM64"),
            patch.object(build, "builder") as builder,
            patch.object(sys, "stderr"),
            self.assertRaises(SystemExit),
        ):
            build.main(argv=["--build-only"])
        builder.assert_not_called()

    def test_candidate_build_selects_arm64_tools_for_the_x64_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "mise.toml").write_text('[tools]\ndotnet = "10.0.403"\n')
            backend = Mock()
            backend.host_architecture.return_value = "arm64"
            compiler, dotnet = root / "msvc", str(root / "dotnet.exe")
            environment = {}
            backend.native_environment.return_value = environment, compiler, dotnet
            native = Mock()
            options = [
                "--build-only",
                "--tooling-source",
                str(root),
                "--tooling-revision",
                "a" * 40,
            ]
            with (
                patch.object(sys, "platform", "win32"),
                patch.dict(os.environ, {"DOTNET_HOST_PATH": "host default"}, clear=True),
                patch.object(build, "select_candidate") as select,
                patch.object(build, "verify_candidate") as verify,
                patch.object(build, "load", return_value=backend),
                patch.object(build, "builder", return_value=native),
                patch.object(build.subprocess, "check_output", return_value="10.0.403\n"),
                patch.object(build.subprocess, "run") as run,
                patch("builtins.print"),
            ):
                build.main(root=root, argv=options)
            select.assert_called_once()
            verify.assert_called_once_with()
            backend.native_environment.assert_called_once_with(
                "arm64", {}, target_architecture="x64"
            )
            backend.build_library.assert_called_once_with(
                native, environment, compiler, "x64", native_host="arm64"
            )
            self.assertEqual(environment["DOTNET_BIN"], dotnet)
            self.assertEqual(
                run.call_args.args[0], ["cargo", "fetch", "--locked", "--target", windows.TARGET]
            )

    def test_hosted_evidence_contains_only_the_installed_x64_package(self):
        for changed, desktop in ((False, True), (False, False), (True, False)):
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

                def run(command, **_options):
                    seen.append(command[1])
                    self.assertEqual(command[-4:], tooling)
                    if command[1] == "tools/check-windows.py":
                        self.assertEqual("--desktop" in command, desktop)
                        native.parent.mkdir(parents=True)
                        native.write_text("{}")
                    elif command[1] == "tools/pack-dotnet.py":
                        self.assertEqual(command[2:4], ["--runtime", "win-x64"])
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
                    elif changed:
                        package.write_bytes(b"changed after acceptance")

                tooling = ["--tooling-source", str(root), "--tooling-revision", "a" * 40]
                options = tooling if desktop else ["--skip-desktop", *tooling]
                (native.parent.parent / "desktop-acceptance").mkdir(parents=True)
                env = {"NAVI_CI_ARTIFACTS": str(output), "DOTNET_BIN": str(root / "dotnet.exe")}
                backend = Mock()
                backend.host_architecture.return_value = "arm64"
                with (
                    patch.object(sys, "platform", "win32"),
                    patch.dict(os.environ, env, clear=True),
                    patch.object(ci, "select_candidate"),
                    patch.object(ci, "load", return_value=backend),
                    patch.object(ci, "verify_candidate"),
                    patch.object(ci.subprocess, "run", side_effect=run),
                ):
                    if changed:
                        with self.assertRaisesRegex(ValueError, "package changed"):
                            ci.main(root=root, argv=options)
                    else:
                        ci.main(root=root, argv=options)
                self.assertEqual(
                    seen,
                    ["tools/check-windows.py", "tools/pack-dotnet.py", "tools/test-package.py"],
                )
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
            project = root / "bindings/dotnet/tests/WindowManagement.NativeTests"
            output = project / "bin/Release/net10.0-windows/win-x64"
            output.mkdir(parents=True)
            (output / "WindowManagement.NativeTests.dll").write_bytes(b"managed fixture")
            library = parent / "window_management_ffi.dll"
            bindings = Mock()
            workspaces = Mock()
            workspaces.temporary_workspace.return_value = nullcontext(workspace)
            run = Mock()
            executable = (
                root / "target" / windows.TARGET / "debug/examples/test_owned_window_target.exe"
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
                    "test_owned_window_target",
                    "--target",
                    windows.TARGET,
                    "--target-dir",
                    root / "target",
                    "--locked",
                    "--offline",
                ]
            )
            tooling = {"bindings": bindings, "workspaces": workspaces}
            with patch.object(build, "load", side_effect=tooling.get):
                if not accepted:
                    with self.assertRaisesRegex(ValueError, "x64 PE executable"):
                        build.run_desktop(root, "dotnet", {}, library, (), run)
                    self.assertEqual(run.call_args_list, [build_target])
                    bindings.stage_native.assert_not_called()
                    workspaces.temporary_workspace.assert_not_called()
                    return
                build.run_desktop(root, "dotnet", {}, library, (), run)
            workspaces.temporary_workspace.assert_called_once_with(
                parent, prefix="desktop-consumer-"
            )
            app = workspace / "app"
            bindings.stage_native.assert_called_once_with(library, app / library.name)
            self.assertEqual((app / executable.name).read_bytes(), executable.read_bytes())
            self.assertEqual(
                run.call_args_list,
                [
                    build_target,
                    call(
                        [
                            "dotnet",
                            app / "WindowManagement.NativeTests.dll",
                            parent / "windows/desktop-acceptance",
                        ]
                    ),
                ],
            )

    def test_desktop_pinned_tooling_reports_fixture_failure_before_cleanup_failure(self):
        missing = ModuleNotFoundError(
            "Pinned tooling has no workspace helper", name="sdk_tooling.workspaces"
        )
        cleanup_error = PermissionError("Native desktop library remains open")
        cleanup_error.winerror = 5
        with tempfile.TemporaryDirectory() as parent:
            for fixture_error in (None, subprocess.CalledProcessError(7, ["dotnet", "fixture"])):
                with (
                    self.subTest(fixture_error=fixture_error),
                    patch.object(build, "load", side_effect=missing),
                    patch.object(tempfile.TemporaryDirectory, "_rmtree", side_effect=cleanup_error),
                    self.assertRaises(type(fixture_error or cleanup_error)) as context,
                ):
                    with build._desktop_workspace(Path(parent)):
                        if fixture_error is not None:
                            raise fixture_error
                self.assertIs(context.exception, fixture_error or cleanup_error)
                if fixture_error is not None:
                    self.assertIn("Native desktop library remains open", fixture_error.__notes__[0])

    def test_desktop_tooling_inner_import_failure_does_not_select_the_fallback(self):
        missing = ModuleNotFoundError("Missing tooling dependency", name="unexpected_extension")
        with (
            patch.object(build, "load", side_effect=missing),
            self.assertRaises(ModuleNotFoundError) as error,
        ):
            with build._desktop_workspace(Path("unused")):
                self.fail("Unexpected workspace")
        self.assertIs(error.exception, missing)


if __name__ == "__main__":
    unittest.main()
