"""Build independent, source-bound universal macOS frameworks for Rust C ABIs."""

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path, PurePosixPath

from .artifacts import (
    DEP_INFO_PARSER,
    build_lock,
    dep_info_sources,
    files,
    hashes,
    publish,
    write_json,
)
from .cargo import CargoDependencies, notice_root, runtime_notices

DARWIN_TARGETS = ("aarch64-apple-darwin", "x86_64-apple-darwin")
NOTICE_TARGETS = (*DARWIN_TARGETS, "aarch64-pc-windows-msvc")


def run(*arguments, env=None, cwd=None):
    return subprocess.check_output(list(map(str, arguments)), env=env, cwd=cwd, text=True).strip()


class NativeBuilder:
    def __init__(
        self,
        root,
        ffi="crates/ffi",
        *,
        symbol_prefix,
        minimum_macos,
        receipt="native-build.json",
        target_directory="target/native",
        notice_packages=None,
        notice_directory="ThirdParty",
        specification="tools/native.py",
    ):
        self.root = Path(root).resolve()
        self.ffi = self.root / ffi
        if not self.ffi.resolve().is_relative_to(self.root):
            raise ValueError("FFI source must be inside its SDK")
        self.manifest = tomllib.loads((self.ffi / "Cargo.toml").read_text())
        self.package = self.manifest["package"]["name"]
        self.notice_packages = tuple(notice_packages or [self.package])
        self.notice_root = notice_root(self.root, notice_directory)
        self.specification = self.root / specification
        if not self.specification.resolve().is_relative_to(self.root):
            raise ValueError("Native specification must be inside its repository")
        self.library = self.manifest.get("lib", {}).get("name", self.package.replace("-", "_"))
        self.module_map = self.ffi / "module.modulemap"
        self.module = re.search(r"\bmodule\s+(\w+)", self.module_map.read_text())[1]
        if not re.fullmatch(r"[A-Za-z_]\w*", symbol_prefix):
            raise ValueError("A C identifier prefix is required")
        if not re.fullmatch(r"\d+\.\d+", minimum_macos):
            raise ValueError("The minimum macOS version must have major.minor form")
        if Path(receipt).name != receipt or not receipt.endswith(".json"):
            raise ValueError("A receipt filename is required")
        self.symbol_prefix = symbol_prefix
        self.minimum_macos = minimum_macos
        self.artifact = self.root / "Artifacts" / (self.module + ".xcframework")
        self.receipt = self.root / "Artifacts" / receipt
        self.targets = DARWIN_TARGETS
        self.target_directory = self.root / target_directory
        if not self.target_directory.resolve().is_relative_to(self.root):
            raise ValueError("Native build output must stay inside its SDK")
        self.compiler = tomllib.loads((self.root / "rust-toolchain.toml").read_text())["toolchain"][
            "channel"
        ]

    @property
    def configuration(self):
        return dict(
            package=self.package,
            library=self.library,
            module=self.module,
            ffi=self.ffi.relative_to(self.root).as_posix(),
            symbolPrefix=self.symbol_prefix,
            minimumMacOS=self.minimum_macos,
            targets=list(self.targets),
            noticePackages=list(self.notice_packages),
            noticeDirectory=self.notice_root.relative_to(self.root).as_posix(),
            specification=self.specification.relative_to(self.root).as_posix(),
        )

    @property
    def version(self):
        version = self.manifest["package"]["version"]
        if isinstance(version, dict) and version.get("workspace") is True:
            version = tomllib.loads((self.root / "Cargo.toml").read_text())["workspace"]["package"][
                "version"
            ]
        if not isinstance(version, str) or not version:
            raise ValueError("The FFI package must declare or inherit its Cargo version")
        return version

    @property
    def headers(self):
        root = self.ffi / "include"
        names = re.findall(r'\bheader\s+"([^"\n]+)"', self.module_map.read_text())
        if not names:
            raise ValueError("The C module map must declare its public headers")
        paths = [root / name for name in names]
        if any(not p.resolve().is_relative_to(root.resolve()) or not p.is_file() for p in paths):
            raise ValueError("Public headers must be files inside the SDK include directory")
        return paths

    def hashes(self, paths, relative_to=None):
        return hashes(paths, relative_to or self.root)

    def _mandatory_sources(self):
        paths = [self.root / name for name in ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml")]
        paths += list((self.root / "crates").rglob("Cargo.toml"))
        paths += list((self.root / "crates").rglob("build.rs"))
        paths += self.headers + [self.module_map]
        paths += [p for p in files(self.notice_root) if p.name != ".DS_Store"]
        for path in (self.root / "LICENSE", self.specification):
            if path.is_file():
                paths.append(path)
        return paths

    def tool_inputs(self):
        root = Path(__file__).resolve().parent
        return hashes([root / name for name in ("native.py", "artifacts.py", "cargo.py")], root) | (
            hashes([root.parent / DEP_INFO_PARSER], root.parent)
        )

    def notices(self):
        paths = [
            p
            for p in files(self.notice_root)
            if p.name not in (".DS_Store", "registry-notices.json")
        ]
        if (self.root / "LICENSE").is_file():
            paths.insert(0, self.root / "LICENSE")
        return b"\n\n".join(
            ("===== " + p.relative_to(self.root).as_posix() + " =====\n").encode() + p.read_bytes()
            for p in paths
        )

    def build_sources(self):
        # Conservative build-time guard. Test-only edits may invalidate a running
        # build, but never force a later rebuild of an accepted production tree.
        return hashes(
            self._mandatory_sources()
            + [p for p in files(self.root / "crates") if p.name != ".DS_Store"],
            self.root,
        )

    def _production_sources(self, parser_sha256, env=None):
        selected = set()
        deps = [
            self.target_directory / target / "release" / ("lib" + self.library + ".d")
            for target in self.targets
        ]
        for path in dep_info_sources(deps, expected_sha256=parser_sha256, cwd=self.root, env=env):
            path = path.resolve()
            if path.is_relative_to(self.root) and not path.is_relative_to(
                self.target_directory.resolve()
            ):
                selected.add(path)
        if self.ffi / "src/lib.rs" not in selected:
            raise ValueError("Production dependency information omits the FFI root")
        return sorted(selected)

    def _input_roots(self, roots):
        if not isinstance(roots, list):
            raise ValueError("Build-script input roots must be a list")
        selected = set()
        outputs = [
            (self.root / name).resolve()
            for name in (".git", "Artifacts", "target", ".native-build")
        ] + [self.target_directory.resolve()]

        def identities(path):
            result = []
            for ancestor in (path, *path.parents):
                try:
                    info = ancestor.stat()
                except FileNotFoundError:
                    result.append(None)
                else:
                    result.append((info.st_dev, info.st_ino))
            return result

        for name in roots:
            if not isinstance(name, str):
                raise ValueError("Build-script input roots must be relative directories")
            relative = PurePosixPath(name)
            if (
                not relative.parts
                or relative.is_absolute()
                or relative.as_posix() != name
                or ".." in relative.parts
                or "\\" in name
                or ":" in name
            ):
                raise ValueError("Build-script input root must be a canonical relative directory")
            path = self.root
            for part in relative.parts:
                path /= part
                if path.is_symlink():
                    raise ValueError("Build-script input root contains a symlink")
            if not path.is_dir():
                raise ValueError("Build-script input root must be an existing directory")
            source_ids = identities(path)
            if source_ids[0] is None:
                raise ValueError("Build-script input root changed during validation")
            for output in outputs:
                # resolve() can retain case aliases. Existing ancestor identities
                # also cover output directories that have not been created yet.
                output_ids = identities(output)
                if (
                    path.is_relative_to(output)
                    or output.is_relative_to(path)
                    or source_ids[0] in output_ids
                    or output_ids[0] is not None
                    and output_ids[0] in source_ids
                ):
                    raise ValueError(
                        "Build-script input root overlaps repository metadata or output"
                    )
            selected.add(path)
        return sorted(selected)

    def _build_script_roots(self, packages):
        roots = []
        for package in packages:
            scripts = [
                Path(target["src_path"])
                for target in package.get("targets", [])
                if "custom-build" in target.get("kind", [])
            ]
            if not scripts:
                continue
            root = Path(package["manifest_path"]).parent
            if not root.is_absolute() or not root.is_relative_to(self.root):
                raise ValueError("Local build-script package escapes the repository")
            relative = root.relative_to(self.root).as_posix()
            self._input_roots([relative])
            for script in scripts:
                if (
                    not script.is_absolute()
                    or not script.is_relative_to(root)
                    or ".." in script.relative_to(root).parts
                ):
                    raise ValueError("Local build script must stay inside its package input root")
                path = root
                for part in script.relative_to(root).parts:
                    path /= part
                    if path.is_symlink():
                        raise ValueError("Local build script contains a symlink")
                if not script.is_file():
                    raise ValueError("Local build script must be an existing ordinary file")
            roots.append(relative)
        return sorted(set(roots))

    def _build_script_inventory(self, roots):
        selected, directories = set(), set()

        def failed(error):
            raise ValueError("Cannot enumerate build-script input tree") from error

        for root in self._input_roots(roots):
            for directory, names, filenames in os.walk(root, followlinks=False, onerror=failed):
                base = Path(directory)
                if base.is_symlink() or not base.is_dir():
                    raise ValueError("Build-script input directory changed while enumerating")
                directories.add(base.relative_to(self.root).as_posix())
                for name in names + filenames:
                    path = base / name
                    if path.is_symlink():
                        raise ValueError("Build-script input tree contains a symlink")
                    if name in names:
                        if not path.is_dir():
                            raise ValueError(
                                "Build-script input tree contains an invalid directory"
                            )
                    elif not path.is_file():
                        raise ValueError("Build-script input tree contains a non-regular file")
                    elif name != ".DS_Store":
                        selected.add(path)
        return sorted(selected), sorted(directories)

    def _input_snapshot(self, production_sources=None, *, build_script_roots=None):
        if production_sources is None:
            previous = json.loads(self.receipt.read_text())
            if "buildScriptInputRoots" not in previous or not isinstance(
                previous.get("buildScriptInputDirectories"), list
            ):
                raise ValueError(
                    "Native receipt lacks build-script inventory; rebuild the artifact"
                )
            production_sources = [self.root / name for name in previous["productionSources"]]
            build_script_roots = previous["buildScriptInputRoots"]
        elif build_script_roots is None:
            raise ValueError("Explicit production sources require build-script input roots")
        for path in production_sources:
            if not path.resolve().is_relative_to(self.root):
                raise ValueError("Production source escapes the SDK")
        script_files, directories = self._build_script_inventory(build_script_roots)
        return (
            hashes(self._mandatory_sources() + list(production_sources) + script_files, self.root),
            directories,
        )

    def inputs(self, production_sources=None, *, build_script_roots=None):
        return self._input_snapshot(production_sources, build_script_roots=build_script_roots)[0]

    def public_symbols(self):
        text = "\n".join(p.read_text() for p in self.headers)
        symbols = set(re.findall(r"\b(" + re.escape(self.symbol_prefix) + r"\w*)\s*\(", text))
        if not symbols:
            raise ValueError("No public C functions match the SDK's declared prefix")
        return {"_" + name for name in symbols}

    def verify_symbols(self, library, env=None):
        for architecture in ("arm64", "x86_64"):
            actual = set(
                run("xcrun", "nm", "-arch", architecture, "-gjU", library, env=env).splitlines()
            )
            if actual != self.public_symbols():
                raise ValueError(
                    "Native exports differ from the C header: "
                    + str(actual ^ self.public_symbols())
                )

    @property
    def _install_name(self):
        return f"@rpath/{self.module}.framework/Versions/A/{self.module}"

    def verify_platform(self, library, env=None):
        architectures = set(run("xcrun", "lipo", "-archs", library, env=env).split())
        if architectures != {"arm64", "x86_64"}:
            raise ValueError("Native framework must contain exactly arm64 and x86_64")
        for architecture in sorted(architectures):
            output = run("xcrun", "vtool", "-arch", architecture, "-show-build", library, env=env)
            if re.findall(r"^\s*platform (\S+)", output, re.M) != ["MACOS"] or re.findall(
                r"^\s*minos (\S+)", output, re.M
            ) != [self.minimum_macos]:
                raise ValueError("Native platform/minimum OS differs from the SDK policy")
            install_name = subprocess.check_output(
                ["xcrun", "otool", "-arch", architecture, "-X", "-D", str(library)],
                env=env,
                text=True,
            )
            if install_name != self._install_name + "\n":
                raise ValueError(f"Native framework install name differs on {architecture}")

    def retain_notices(self, env=None):
        env = env or os.environ.copy()
        relative = self.notice_root.relative_to(self.root).as_posix()
        runtime_notices(self.root, env, notice_directory=relative)
        CargoDependencies(self.root, self.notice_packages, NOTICE_TARGETS, env).retain_notices(
            notice_directory=relative
        )

    def dependencies(self, env, targets=None):
        graph = CargoDependencies(self.root, [self.package], targets or self.targets, env)
        result = graph.provenance()
        graph.configure_remaps(env)
        return result

    def verify(self, env=None, *, inspect_native=True):
        env = env or os.environ.copy()
        receipt = json.loads(self.receipt.read_text())
        if receipt.get("schema") != 3 or receipt.get("configuration") != self.configuration:
            raise ValueError("Native build contract changed; rebuild with the pinned tooling")
        if (
            receipt.get("toolInputs") != self.tool_inputs()
            or (
                receipt["inputs"],
                receipt.get("buildScriptInputDirectories"),
            )
            != self._input_snapshot()
        ):
            raise ValueError(
                "Production source, build tooling or notices changed; rebuild the native artifact"
            )
        if not receipt["compiler"].startswith("rustc " + self.compiler + " "):
            raise ValueError("Native compiler differs from rust-toolchain.toml")
        if receipt["outputs"] != hashes(files(self.artifact), self.root):
            raise ValueError("Native artifact differs from its receipt")
        framework = self.artifact / "macos-arm64_x86_64" / (self.module + ".framework")
        info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
        if info["MinimumOSVersion"] != self.minimum_macos:
            raise ValueError("Framework metadata differs from the SDK minimum OS")
        if inspect_native:
            self.verify_platform(framework / self.module, env)
            self.verify_symbols(framework / self.module, env)
            subprocess.run(
                ["codesign", "--verify", "--strict", str(framework)], env=env, check=True
            )
        print(
            "Native artifact matches production sources, toolchain, ABI and retained notices: "
            + self.module
        )

    def build(self, env=None):
        with build_lock(self.root / ".native-build"):
            self._build(env)

    def _build(self, env):
        if sys.platform != "darwin":
            raise ValueError("XCFramework generation requires native macOS tools")
        env = dict(
            env or os.environ,
            MACOSX_DEPLOYMENT_TARGET=self.minimum_macos,
            CARGO_PROFILE_RELEASE_STRIP="none",
            ZERO_AR_DATE="1",
        )
        compiler = run("rustc", "--version", "--verbose", env=env)
        if not compiler.startswith("rustc " + self.compiler + " "):
            raise ValueError("Preinstall the SDK's pinned Rust compiler and Darwin targets")
        tool_inputs = self.tool_inputs()
        self.retain_notices(env)
        graph = CargoDependencies(self.root, [self.package], self.targets, env)
        dependencies = graph.provenance()
        graph.configure_remaps(env)
        script_roots = self._build_script_roots(graph.workspace_packages)
        env["CARGO_TARGET_DIR"] = str(self.target_directory)
        env["CARGO_ENCODED_RUSTFLAGS"] += (
            "\x1f-Clink-arg=-mmacosx-version-min=" + self.minimum_macos
        )
        before = self.build_sources()
        before_directories = self._build_script_inventory(script_roots)[1]
        previous_outputs = hashes(files(self.root / "Artifacts"), self.root)
        # Let the final library link lay out Mach-O with its installed name.
        for target in self.targets:
            subprocess.run(
                [
                    "cargo",
                    "rustc",
                    "-p",
                    self.package,
                    "--lib",
                    "--release",
                    "--target",
                    target,
                    "--locked",
                    "--offline",
                    "--",
                    f"-Clink-arg=-Wl,-install_name,{self._install_name}",
                    "-Clink-arg=-Xlinker",
                    "-Clink-arg=-oso_prefix",
                    "-Clink-arg=-Xlinker",
                    f"-Clink-arg={self.target_directory.resolve()}/",
                ],
                cwd=self.root,
                env=env,
                check=True,
            )
        production = self._production_sources(tool_inputs[DEP_INFO_PARSER.as_posix()], env)
        source_inputs, script_directories = self._input_snapshot(
            production, build_script_roots=script_roots
        )
        if script_directories != before_directories:
            raise ValueError("Build-script input directories changed during build")
        if self.tool_inputs() != tool_inputs:
            raise ValueError("Native build tooling changed during build")
        directory = self.root / ".native-build"
        directory.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            work = Path(temporary)
            stage = work / "Artifacts"
            destination = self.root / "Artifacts"
            if destination.is_symlink():
                raise ValueError("Artifact destination must not be a symlink")
            if destination.exists():
                shutil.copytree(destination, stage, symlinks=True)
            else:
                stage.mkdir()
            framework = work / (self.module + ".framework")
            contents = framework / "Versions/A"
            for name in ("Headers", "Modules", "Resources"):
                (contents / name).mkdir(parents=True)
                (framework / name).symlink_to("Versions/Current/" + name)
            (framework / "Versions/Current").symlink_to("A")
            (framework / self.module).symlink_to("Versions/Current/" + self.module)
            library = contents / self.module
            run(
                "xcrun",
                "lipo",
                "-create",
                *[
                    self.target_directory / target / "release" / ("lib" + self.library + ".dylib")
                    for target in self.targets
                ],
                "-output",
                library,
                env=env,
            )
            run("xcrun", "strip", "-S", library, env=env)
            self.verify_platform(library, env)
            self.verify_symbols(library, env)
            for header in self.headers:
                destination_header = contents / "Headers" / header.relative_to(self.ffi / "include")
                destination_header.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(header, destination_header)
            shutil.copyfile(self.module_map, contents / "Modules/module.modulemap")
            version = self.version
            (contents / "Resources/Info.plist").write_bytes(
                plistlib.dumps(
                    dict(
                        CFBundleIdentifier="com.naviapps.native." + self.module,
                        CFBundleName=self.module,
                        CFBundleExecutable=self.module,
                        CFBundlePackageType="FMWK",
                        CFBundleVersion=version,
                        CFBundleShortVersionString=version,
                        MinimumOSVersion=self.minimum_macos,
                    )
                )
            )
            # Keep verbatim notices without deep framework paths in Git checkouts
            # on Windows. Original files remain independently retained in the SDK.
            (contents / "Resources/ThirdPartyNotices.txt").write_bytes(self.notices())
            # An anonymous local signature seals the complete framework; no key is used.
            run("codesign", "--force", "--sign", "-", "--timestamp=none", framework, env=env)
            output = stage / self.artifact.name
            if output.exists():
                shutil.rmtree(output)
            run(
                "xcodebuild",
                "-create-xcframework",
                "-framework",
                framework,
                "-output",
                output,
                env=env,
            )
            header_text = "\n".join(p.read_text() for p in self.headers)
            abi = re.search(r"#define\s+\w+_ABI_VERSION\s+(\d+)U?\b", header_text)
            record = dict(
                schema=3,
                configuration=self.configuration,
                compiler=compiler,
                deploymentTarget=self.minimum_macos,
                linkage="dynamic-framework",
                architectures=["arm64", "x86_64"],
                exportedSymbols=sorted(self.public_symbols()),
                abiVersion=int(abi[1]) if abi else None,
                dependencies=dependencies,
                toolInputs=tool_inputs,
                productionSources=[p.relative_to(self.root).as_posix() for p in production],
                buildScriptInputRoots=script_roots,
                buildScriptInputDirectories=script_directories,
                inputs=source_inputs,
                outputs=hashes(files(output), work),
            )
            pins = self.root / "tools/tooling-sources.json"
            if pins.is_file():
                record["tooling"] = json.loads(pins.read_text())
            write_json(stage / self.receipt.name, record)
            if (
                self.dependencies(dict(env)) != dependencies
                or self.build_sources() != before
                or self.tool_inputs() != tool_inputs
                or hashes(files(destination), self.root) != previous_outputs
                or self._input_snapshot(production, build_script_roots=script_roots)
                != (source_inputs, script_directories)
            ):
                raise ValueError(
                    "SDK source or artifact changed during build; staged output was not installed"
                )
            publish(stage, destination, lambda: self.verify(env))


def main(builders, argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args(argv)
    for builder in builders:
        builder.verify() if args.verify else builder.build()
